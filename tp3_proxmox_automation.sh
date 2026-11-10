#!/bin/bash
# tp3.sh - usage : ./tp3.sh [t1 t2 ... t10]   (sans argument = tout)
exec > >(tee -a /root/tp3.log) 2>&1
SSHO="-o StrictHostKeyChecking=no -o BatchMode=yes"
: > /tmp/tp3_answers

on() { if [ "$1" = pve1 ]; then bash -c "$2"; else ssh $SSHO root@$1 "$2"; fi; }
assert() { if eval "$2"; then echo "  ✓ $1"; else echo "  ✘ $1"; return 1; fi; }
ok() { # ok <n> <instruction guide>
  echo -e "\n\e[32m✔ Tâche $1 terminée avec succès\e[0m"; shift; echo -e "  → Dans le guide : $*"
}
ans() { echo "$1" >> /tmp/tp3_answers; }
wait_ok() { for i in $(seq 1 ${1:-60}); do ceph health | grep -q HEALTH_OK && return 0; sleep 5; done; ceph -s; return 1; }
json() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

t1() {
  lsblk -d -o NAME,SIZE,TYPE; pvecm status | grep -E "Nodes|Quorate"
  n=$(lsblk -dn -o NAME,SIZE | grep -cE '^sd[bcd] +8G')
  assert "3 disques de 8G sur pve1" "[ $n -eq 3 ]"
  assert "cluster quorate" "pvecm status | grep -q 'Quorate: *Yes'"
  for h in pve2 pve3; do assert "$h : sdb/sdc/sdd présents" "[ \$(on $h \"lsblk -dn -o NAME,SIZE | grep -cE '^sd[bcd] +8G'\") -eq 3 ]"; done
  ans "Tâche 1 (étape 81) : $n"
  ok 1 "étape 1, saisir la réponse : $n   puis Submit answer"
}

t2() {
  for h in pve1 pve2; do
    on $h "zpool list tank >/dev/null 2>&1 || zpool create -o ashift=12 tank mirror /dev/sdb /dev/sdc
           zfs set compression=lz4 tank; zfs set atime=off tank
           zfs list tank/vm >/dev/null 2>&1 || zfs create tank/vm
           echo 'options zfs zfs_arc_max=1073741824' > /etc/modprobe.d/zfs.conf
           echo 1073741824 > /sys/module/zfs/parameters/zfs_arc_max
           update-initramfs -u -k all"
  done
  pvesm status | grep -q '^tp-zfs' || pvesm add zfspool tp-zfs --pool tank/vm --content images,rootdir --sparse 1 --blocksize 16k --nodes pve1,pve2
  zpool status tank; pvesm status
  assert "pool ONLINE sur pve1" "zpool status tank | grep -q 'state: ONLINE'"
  assert "pool ONLINE sur pve2" "on pve2 'zpool status tank' | grep -q 'state: ONLINE'"
  assert "tp-zfs actif" "pvesm status | grep tp-zfs | grep -q active"
  ans "Tâche 2 (étape 82) : 2"
  ok 2 "saisir : 2   (disques du vdev mirror-0)"
}

t3() {
  qm status 300 >/dev/null 2>&1 || qm create 300 --name zfs-test --memory 1024 --cores 1 --scsihw virtio-scsi-single --scsi0 tp-zfs:4,iothread=1,discard=on --net0 virtio,bridge=vmbr0 --ostype l26
  Z=/dev/zvol/tank/vm/vm-300-disk-0
  dd if=/dev/urandom of=$Z bs=1M count=2000 status=none; sync
  zfs list -o name,used,refer,usedbysnapshots -r tank/vm
  qm listsnapshot 300 | grep -q avant-ecriture || qm snapshot 300 avant-ecriture
  dd if=/dev/urandom of=$Z bs=1M count=2000 status=none; sync
  zfs list -o name,used,refer,usedbysnapshots -r tank/vm
  zfs list -t snapshot -o name,used -r tank/vm
  used=$(zfs get -Hp -o value usedbysnapshots tank/vm/vm-300-disk-0)
  assert "usedbysnapshots > 1 GiB ($used octets)" "[ $used -gt 1073741824 ]"
  ans "Tâche 3 (étape 83) : yes"
  ok 3 "saisir : yes   (usedbysnapshots dépasse 1 GiB)"
}

t4() {
  pvesr list | grep -q 300-0 || pvesr create-local-job 300-0 pve2 --schedule "*/5" --rate 50
  pvesr run --id 300-0 --verbose
  pvesr status
  on pve2 "zfs list -t snapshot tank/vm/vm-300-disk-0"
  assert "snapshots de réplication sur pve2" "on pve2 'zfs list -t snapshot -H tank/vm/vm-300-disk-0' | grep -q __replicate_"
  echo ">> étape 2 : mesure du RPO"
  M=$(date +%s); echo $M > /root/marqueur.txt
  sleep 3; pvesr run --id 300-0 --verbose >/dev/null
  S=$(on pve2 "zfs list -t snapshot -H -o name -s creation tank/vm/vm-300-disk-0 | tail -1")
  C=$(on pve2 "zfs get -Hp -o value creation $S")
  echo "  marqueur=$M  dernier snapshot=$C ($S)  écart=$((C-M)) s"
  assert "écart <= 300 s" "[ $((C-M)) -le 300 ]"
  ans "Tâche 4 : étape 84 = bouton 'Check this step' ; étape 85 = rien à saisir (rapport : RPO mesuré ≈ $((C-M)) s, intervalle 5 min)"
  ok 4 "étape 1 (84) : clique 'Check this step'. Étape 2 (85) : rien à valider, note l'écart RPO pour ton rapport"
}

t5() {
  [ -f /etc/pve/ceph.conf ] || pveceph init --network 10.10.30.0/24
  for h in pve1 pve2 pve3; do
    on $h "[ -d /var/lib/ceph/mon/ceph-$h ] || pveceph mon create"
  done
  for h in pve1 pve2; do
    on $h "[ -d /var/lib/ceph/mgr/ceph-$h ] || pveceph mgr create" || true
  done
  chronyc tracking | grep -E "System time"; sleep 5
  wait_ok 60 || echo "  (HEALTH non OK : clock skew ? attends 2-3 min puis relance ./tp3.sh t5)"
  ceph -s
  n=$(ceph mon stat -f json | json 'len(d["quorum"])')
  assert "3 moniteurs en quorum" "[ $n -eq 3 ]"
  assert "HEALTH_OK" "ceph health | grep -q HEALTH_OK"
  ans "Tâche 5 (étape 86) : $n"
  ok 5 "saisir : $n   (nombre de moniteurs, ceph mon stat)"
}

t6() {
  for h in pve1 pve2 pve3; do
    on $h "[ -n \"\$(ls /var/lib/ceph/osd 2>/dev/null)\" ] || pveceph osd create /dev/sdd"
  done
  for i in $(seq 1 40); do
    u=$(ceph osd stat -f json | json 'min(d["num_up_osds"],d["num_in_osds"])'); [ "$u" -ge 3 ] && break; sleep 5
  done
  ceph osd pool ls | grep -qx tp-rbd || pveceph pool create tp-rbd --size 3 --min_size 2 --pg_autoscale_mode on --add_storages 1
  wait_ok 60 || true
  ceph -s; ceph osd tree; ceph osd df tree; pvesm status
  assert "3 OSD up et in" "[ $u -ge 3 ]"
  assert "tp-rbd dans pvesm" "pvesm status | grep -q tp-rbd"
  pg=$(ceph osd pool get tp-rbd pg_num -f json | json 'd["pg_num"]')
  ans "Tâche 6 (étape 87) : $pg"
  ok 6 "saisir : $pg   (pg_num de tp-rbd ; si refusé : ceph osd pool autoscale-status et prends la valeur actuelle)"
}

t7() {
  qm status 301 >/dev/null 2>&1 || qm create 301 --name ceph-test --memory 1024 --cores 1 --scsihw virtio-scsi-single --scsi0 tp-rbd:4,iothread=1,discard=on --net0 virtio,bridge=vmbr0 --ostype l26
  qm status 301 | grep -q running || qm start 301
  sleep 5
  time qm migrate 301 pve2 --online
  assert "301 tourne sur pve2" "on pve2 'qm status 301' | grep -q running"
  ok 7 "clique 'Check this step' (étape 88)"
}

t8() {
  on pve2 "qm status 301 | grep -q running && qm migrate 301 pve1 --online" || true   # retour sur pve1 pour suivre le guide
  N=$(on pve3 "ls /var/lib/ceph/osd" | head -1 | sed 's/ceph-//')
  echo "OSD de pve3 = $N"
  on pve3 "systemctl stop ceph-osd@$N"
  sleep 40
  ceph health detail | head -15; ceph -s
  assert "Ceph en HEALTH_WARN (dégradé)" "ceph health | grep -q HEALTH_WARN"
  assert "VM 301 toujours running" "qm status 301 | grep -q running"
  on pve3 "systemctl start ceph-osd@$N"
  wait_ok 120 || true
  ceph -s; ceph osd df tree
  assert "retour en HEALTH_OK" "ceph health | grep -q HEALTH_OK"
  ans "Tâche 8 (étape 89) : $N"
  ok 8 "saisir : $N   (numéro de l'OSD de pve3)"
}

t9() {
  command -v fio >/dev/null || apt-get install -y fio
  qm stop 301 2>/dev/null || true
  F="--rw=randwrite --bs=4k --iodepth=1 --numjobs=1 --size=1G --runtime=60 --time_based --direct=1 --ioengine=libaio --percentile_list=50:95:99 --output-format=json"
  fio --name=lat --filename=/dev/zvol/tank/vm/vm-300-disk-0 $F --output=/root/fio-zfs.json
  D=$(rbd map tp-rbd/vm-301-disk-0)
  fio --name=lat --filename=$D $F --output=/root/fio-rbd.json
  rbd unmap $D
  for f in zfs rbd; do
    python3 - /root/fio-$f.json $f <<'EOF'
import json,sys
p=json.load(open(sys.argv[1]))["jobs"][0]["write"]["clat_ns"]["percentile"]
print(sys.argv[2], {k[:2]+"%":round(v/1000) for k,v in sorted(p.items(), key=lambda x: float(x[0]))}, "(µs)")
EOF
  done
  assert "fio-zfs.json et fio-rbd.json existent" "[ -s /root/fio-zfs.json ] && [ -s /root/fio-rbd.json ]"
  ok 9 "clique 'Check this step' (étape 90). Analyses 13-15 : compare les latences affichées ci-dessus"
}

t10() {
  echo "Rien à exécuter : le résumé se rédige dans ton rapport."
  echo "Tes sorties sont dans /root/tp3.log ; fio : /root/fio-zfs.json et /root/fio-rbd.json"
  ok 10 "pas de validation automatique (étape 91)"
}

ALL="t1 t2 t3 t4 t5 t6 t7 t8 t9 t10"
for t in ${@:-$ALL}; do
  echo -e "\n=================== $t ==================="
  ( set -e; $t ); rc=$?
  [ $rc -ne 0 ] && { echo -e "\n\e[31m✘ $t a échoué : corrige puis relance ./tp3.sh $t\e[0m"; exit 1; }
done
echo -e "\n=========== RÉCAP À SAISIR DANS LE GUIDE ==========="; cat /tmp/tp3_answers
