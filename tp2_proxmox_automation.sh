#!/bin/bash
# tp2.sh  -  usage : ./tp2.sh [etape ...]   (sans argument = tout)
# etapes : prereq bond ct failover sdn vxlan capture mtu evpn routage evpnfail
TPL="debian-12-standard_12.12-1_amd64.tar.zst"
SSH="ssh -o StrictHostKeyChecking=no -o BatchMode=yes"

on() { # on <noeud> <commande>
  if [ "$1" = pve1 ]; then bash -c "$2"; else $SSH root@$1 "$2"; fi
}
mkct() { # mkct <noeud> <id> <net0>
  on $1 "pct status $2 >/dev/null 2>&1 || { pct create $2 local:vztmpl/$TPL --hostname ct$2 --memory 256 --rootfs local-lvm:2 --net0 '$3' --unprivileged 1 --features nesting=1; }; pct start $2 2>/dev/null; true"
}
repoint() { # repoint <noeud> <id> <net0>
  on $1 "pct stop $2 2>/dev/null; pct set $2 --net0 '$3'; pct start $2"
}
apply_sdn() { pvesh set /cluster/sdn; sleep 8; }

prereq() {
  pvecm status | grep -E "Nodes|Quorate"
  ip -br link
  for n in pve2 pve3; do   # le template doit exister sur chaque noeud
    on $n "ls /var/lib/vz/template/cache/$TPL" >/dev/null 2>&1 || \
      scp -o StrictHostKeyChecking=no /var/lib/vz/template/cache/$TPL root@$n:/var/lib/vz/template/cache/
  done
}

bond() {
  for n in pve1 pve2 pve3; do
    on $n "grep -q '^iface bond0' /etc/network/interfaces" && continue
    on $n "cat >> /etc/network/interfaces" <<'EOF'

auto ens22
iface ens22 inet manual

auto ens23
iface ens23 inet manual

auto bond0
iface bond0 inet manual
    bond-slaves ens22 ens23
    bond-miimon 100
    bond-mode active-backup
    bond-primary ens22

auto vmbr1
iface vmbr1 inet manual
    bridge-ports bond0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094
EOF
    on $n "ifreload -a -n && ifreload -a"
  done
  cat /proc/net/bonding/bond0
}

ct() {
  mkct pve1 201 "name=eth0,bridge=vmbr1,tag=50,ip=192.168.50.201/24"
  mkct pve1 202 "name=eth0,bridge=vmbr1,tag=50,ip=192.168.50.202/24"
  mkct pve1 203 "name=eth0,bridge=vmbr1,tag=60,ip=192.168.50.203/24"
  mkct pve2 214 "name=eth0,bridge=vmbr1,tag=50,ip=192.168.50.214/24"
  sleep 5
  bridge vlan show | grep -E "veth20[123]i0" -A1
  pct exec 201 -- ping -c 3 192.168.50.202            # doit passer
  pct exec 201 -- ping -c 3 -W 2 192.168.50.203 || echo ">> echec attendu (VLAN differents)"
}

failover() {
  pct exec 201 -- ping -i 0.2 -c 150 192.168.50.214 > /tmp/ping_bond.log 2>&1 &
  sleep 5
  ip link set ens22 down; sleep 2
  grep "Currently Active Slave" /proc/net/bonding/bond0     # ens23
  sleep 5
  ip link set ens22 up; sleep 3
  grep "Currently Active Slave" /proc/net/bonding/bond0     # ens22
  wait; tail -3 /tmp/ping_bond.log
}

sdn() {
  pvesh create /cluster/sdn/zones --zone labvlan --type vlan --bridge vmbr1 --nodes pve1,pve2,pve3
  pvesh create /cluster/sdn/vnets --vnet vlab50 --zone labvlan --tag 50
  pvesh create /cluster/sdn/vnets --vnet vlab60 --zone labvlan --tag 60
  apply_sdn
  for n in pve1 pve2 pve3; do for v in vlab50 vlab60; do on $n "ip -br link show $v"; done; done
}

vxlan() {
  pvesh create /cluster/sdn/zones --zone vxlab --type vxlan --peers 10.10.30.1,10.10.30.2,10.10.30.3 --nodes pve1,pve2,pve3 --mtu 1450
  pvesh create /cluster/sdn/vnets --vnet loc01 --zone vxlab --tag 10001
  pvesh create /cluster/sdn/vnets --vnet loc02 --zone vxlab --tag 10002
  apply_sdn
  ip -d link show type vxlan | grep -E "vxlan_loc|dstport"        # dstport 4789
  # locataires : memes adresses 192.168.1.10 / .11
  repoint pve1 201 "name=eth0,bridge=loc01,ip=192.168.1.10/24"
  repoint pve1 203 "name=eth0,bridge=loc02,ip=192.168.1.10/24"
  mkct pve2 204 "name=eth0,bridge=loc01,ip=192.168.1.11/24"
  mkct pve3 205 "name=eth0,bridge=loc02,ip=192.168.1.11/24"
  sleep 8
  pct exec 201 -- ping -c 3 192.168.1.11
  pct exec 203 -- ping -c 3 192.168.1.11
}

capture() {
  command -v tcpdump >/dev/null || apt-get install -y tcpdump
  pct exec 201 -- ping -c 15 192.168.1.11 >/dev/null &
  tcpdump -ni ens21 udp port 4789 -c 10 -v
  wait
}

mtu() {
  pct exec 201 -- ip link set eth0 mtu 1500
  pct exec 201 -- ping -c 2 192.168.1.11
  pct exec 201 -- ping -M do -s 1472 -c 3 -W 2 192.168.1.11 || echo ">> echec attendu"
  for s in 1450 1422 1400; do echo "-s $s :"; pct exec 201 -- ping -M do -s $s -c 2 -W 2 192.168.1.11 | tail -2; done
  pct exec 201 -- ip link set eth0 mtu 1450
  pct exec 201 -- ping -M do -s 1422 -c 3 192.168.1.11            # passe
  pct exec 201 -- ping -M do -s 1423 -c 2 -W 2 192.168.1.11 || echo ">> echec attendu"
}

evpn() {
  for n in pve1 pve2 pve3; do on $n "command -v vtysh >/dev/null || apt-get install -y frr frr-pythontools"; done
  pvesh create /cluster/sdn/controllers --controller evpn1 --type evpn --asn 65000 --peers 10.10.30.1,10.10.30.2,10.10.30.3
  pvesh create /cluster/sdn/zones --zone evpnlab --type evpn --controller evpn1 --vrf-vxlan 20000 --exitnodes pve1,pve2 --nodes pve1,pve2,pve3 --mtu 1450
  pvesh create /cluster/sdn/vnets --vnet evweb --zone evpnlab --tag 20001
  pvesh create /cluster/sdn/vnets/evweb/subnets --subnet 10.20.1.0/24 --gateway 10.20.1.1 --snat 1 --type subnet
  pvesh create /cluster/sdn/vnets --vnet evbdd --zone evpnlab --tag 20002
  pvesh create /cluster/sdn/vnets/evbdd/subnets --subnet 10.20.2.0/24 --gateway 10.20.2.1 --type subnet
  apply_sdn; sleep 10
  vtysh -c "show bgp summary"
  vtysh -c "show ip route vrf vrf_evpnlab"
}

routage() {
  mkct pve3 206 "name=eth0,bridge=evweb,ip=10.20.1.10/24,gw=10.20.1.1"
  mkct pve2 207 "name=eth0,bridge=evbdd,ip=10.20.2.10/24,gw=10.20.2.1"
  sleep 8
  on pve3 "pct exec 206 -- ping -c 3 10.20.2.10"
  on pve3 "pct exec 206 -- ping -c 3 1.1.1.1"
}

evpnfail() {
  on pve3 "pct exec 206 -- ping -i 0.5 -c 80 1.1.1.1 > /tmp/ping_exit.log 2>&1" &
  sleep 8
  systemctl stop frr; sleep 20
  systemctl start frr; sleep 10
  wait; tail -4 /tmp/ping_exit.log
}

ALL="prereq bond ct failover sdn vxlan capture mtu evpn routage evpnfail"
for s in ${@:-$ALL}; do echo -e "\n===== $s ====="; $s; done

cat <<'EOF'

Reponses a saisir dans le guide :
  Tache 1 : 3                          Tache 2 : Fault-tolerance (active-backup) puis ens22
  Tache 6 : 4789                       Tache 7 : 1422
  Tache 8 : pve1,pve2
Ensuite cliquer "Check this step" sur les etapes sans question (72, 74, 78, 79).
EOF
