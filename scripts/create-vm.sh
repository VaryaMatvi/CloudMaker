#!/bin/bash
set -e
echo "Создание диска..."
sudo qemu-img create -f qcow2 -F qcow2 -b /var/lib/libvirt/images/base-ubuntu-24.04.qcow2 /var/lib/libvirt/images/Varya_vm.qcow2 10G
echo "Сбор образа..."
cloud-localds varya-vm.iso cloud-init/user-data cloud-init/meta-data
sudo mv varya-vm.iso /var/lib/libvirt/images/
echo "Создание ВМ"
sudo virt-install   --connect qemu:///system   --name varya-vm   --memory 1024   --vcpus 1   --import   --disk path=/var/lib/libvirt/images/Varya_vm.qcow2,format=qcow2   --disk path=/var/lib/libvirt/images/varya-vm.iso,device=cdrom   --os-variant ubuntu24.04   --network network=default   --graphics none   --noautoconsole
