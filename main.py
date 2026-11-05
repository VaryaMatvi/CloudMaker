import json
import os
import re
import subprocess
import tempfile
from typing import Optional

import libvirt
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

IMAGES_DIR = "/var/lib/libvirt/images"
BASE_IMAGE = f"{IMAGES_DIR}/base-ubuntu-24.04.qcow2" 
NETWORK = "default"

app = FastAPI(title="CloudMaker")
conn = libvirt.open("qemu:///system") 

NAME_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$")
STATES = {1: "running", 2: "blocked", 3: "paused", 4: "shutting-down", 5: "shutoff", 6: "crashed"}
DOMAIN_XML = """
<domain type='kvm'>
  <name>{name}</name>
  <memory unit='MiB'>{memory_mb}</memory>
  <vcpu>{vcpus}</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features><acpi/><apic/></features>
  <cpu mode='host-passthrough'/>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='{disk}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='{file_iso}'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>
    <interface type='network'>
      <source network='{network}'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'><target port='0'/></serial>
    <console type='pty'><target type='serial' port='0'/></console>
  </devices>
</domain>
"""

def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"{cmd[0]}: {r.stderr.strip()}")


def find(name):
    try:
        return conn.lookupByName(name)
    except libvirt.libvirtError:
        raise HTTPException(404, f"ВМ '{name}' не найдена")


def describe(dom):
    state, _reason = dom.state()
    info = dom.info()  
    ips = []
    if dom.isActive():
        try:
            ifaces = dom.interfaceAddresses(libvirt.VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_LEASE)
            for iface in ifaces.values():
                for a in iface["addrs"] or []:
                    if a["type"] == libvirt.VIR_IP_ADDR_TYPE_IPV4:
                        ips.append(a["addr"])
        except libvirt.libvirtError:
            pass  
    return {"name": dom.name(), "state": STATES.get(state, "other"),
            "vcpus": info[3], "memory_mb": info[1] // 1024, "ips": ips}


def disk_paths(name):
    return f"{IMAGES_DIR}/{name}.qcow2", f"{IMAGES_DIR}/{name}.iso"

class VmCreate(BaseModel):
    name: str
    ssh_public_key: str
    vcpus: int = Field(1, ge=1, le=8)
    memory_mb: int = Field(1024, ge=256, le=16384)
    disk_gb: int = Field(5, ge=5, le=100) 
    username: str = "annonimus"
    hostname: Optional[str] = None          
    user_data: Optional[str] = None          

@app.get("/vms")
def list_vms():
    return [describe(d) for d in conn.listAllDomains()]


@app.get("/vms/{name}")
def get_vm(name: str):
    return describe(find(name))


@app.post("/vms", status_code=201)
def create_vm(body: VmCreate):
    hostname = body.hostname or body.name
    if not NAME_RE.match(body.name) or not NAME_RE.match(hostname):
        raise HTTPException(400, "имя и hostname: a-z, 0-9 и дефис, без подчёркиваний")
    if not os.path.exists(BASE_IMAGE):
        raise HTTPException(500, f"базовый образ не найден: {BASE_IMAGE}")
    if any(d.name() == body.name for d in conn.listAllDomains()):
        raise HTTPException(409, f"ВМ '{body.name}' уже существует")

    disk, file_iso = disk_paths(body.name)
    try:
        run(["qemu-img", "create", "-f", "qcow2", "-F", "qcow2",
             "-b", BASE_IMAGE, disk, f"{body.disk_gb}G"])

        if body.user_data:
            user_data = body.user_data
        else:
            cfg = {"hostname": hostname, "manage_etc_hosts": True,
                   "users": [{"name": body.username,
                              "sudo": "ALL=(ALL) NOPASSWD:ALL",
                              "shell": "/bin/bash",
                              "ssh_authorized_keys": [body.ssh_public_key]}]}

            user_data = "#cloud-config\n" + json.dumps(cfg) + "\n"
        meta_data = (f"instance-id: {body.name}\n"
                     f"local-hostname: {hostname}\n")

        with tempfile.TemporaryDirectory() as tmp:
            ud, md = f"{tmp}/user-data", f"{tmp}/meta-data"
            with open(ud, "w") as f:
                f.write(user_data)
            with open(md, "w") as f:
                f.write(meta_data)
            run(["cloud-localds", file_iso, ud, md])

        xml = DOMAIN_XML.format(name=body.name, memory_mb=body.memory_mb,
                                vcpus=body.vcpus, disk=disk, file_iso=file_iso, network=NETWORK)
        dom = conn.defineXML(xml)
        dom.create()
    except Exception as e:
        for p in (disk, file_iso):
            if os.path.exists(p):
                os.remove(p)
        try:
            conn.lookupByName(body.name).undefine()
        except libvirt.libvirtError:
            pass
        raise HTTPException(500, str(e))
    return describe(dom)


@app.post("/vms/{name}/start")
def start_vm(name: str):
    dom = find(name)
    if dom.isActive():
        raise HTTPException(409, "ВМ уже запущена")
    dom.create()
    return describe(dom)


@app.post("/vms/{name}/stop")
def stop_vm(name: str, force: bool = False):
    dom = find(name)
    if not dom.isActive():
        raise HTTPException(409, "ВМ уже остановлена")
    if force:
        dom.destroy()  
    else:
        dom.shutdown()   
    return describe(dom)


@app.delete("/vms/{name}")
def delete_vm(name: str):
    dom = find(name)
    if dom.isActive():
        dom.destroy()
    dom.undefine()
    for p in disk_paths(name):   
        if os.path.exists(p):
            os.remove(p)
    return {"deleted": name}