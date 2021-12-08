#!/bin/bash
set -e

# some vars
ORACLE_HOME=/u01/app/oracle/product/11.2.0.4/gridhome_1
memtotal_kb=$(awk '/^MemTotal/ {print $2}' /proc/meminfo)

hugepages() {
    
    echo "+++Configuring hugepages..."
    
    local page_size_kb=2048
    local pages=$(expr $memtotal_kb / 2 / $page_size_kb)
    local memlock_limit=$(expr $pages \* $page_size_kb)

    # configure huge pages
    sed -ri 's/^vm.nr_hugepages.*$/vm.nr_hugepages='"$pages"'/' /etc/sysctl.conf
    sysctl -p

    # check pages
    local pages_created=$(awk '/^HugePages_Total/ {print $2}' /proc/meminfo)

    # repeat if necessary, wait up to 5 minutes
    local i=0
    if [[ "$pages_created" -lt "$pages" ]]; then
        if [[ "$i" == '5' ]]; then
            echo "only $pages_created, expected $pages"
            break
        fi
        sleep 60
        sysctl -p
        pages_created=$(awk '/^HugePages_Total/ {print $2}' /proc/meminfo)
        ((i++))
    fi
    echo "created [$pages_created/$pages] hugepages"

    # update memory limits
    sed -ri '/^\*[^0-9]+/ s/[0-9]+/'"$memlock_limit"'/' /etc/security/limits.d/99-grid-oracle-limits.conf
}

swap_disk() {

    echo "+++Configuring swap partition..."
    # get current swap partition
    local swap_disk=$(awk '/partition/ {print $1}' /proc/swaps)
    
    # set a label for swap partition
    local swap_label="swap"

    swapoff "$swap_disk"
    mkswap "$swap_disk" -L "$swap_label"

    # update fstab
    sed -ri "/^UUID=.*swap/ s/^UUID=\S+/LABEL=$swap_label/" /etc/fstab

    # activate swap
    swapon LABEL="$swap_label"
}

disks() {
    
    echo "+++Resizing ASM disks..."
    # find the oracleasm partitions
    IFS=$'\n'
    local devices=($(lsblk -npf -o FSTYPE,PKNAME | awk '/oracleasm/ {print $2}'))
    unset IFS

    for item in "${devices[@]}"; do
        echo "resizing device ${item}"
        parted --script "${item}" resizepart 1 100%
    done
}

reconfigure_oracle_has() {
    
    echo "+++Reconfiguring Oracle HAS..."

    # kill anything on port 1521
    fuser -k -n tcp 1521 || true

    # update hostname in listener file
    sed -ri "s/(HOST = )([^\)]*)/\1$HOSTNAME/" /u01/app/oracle/product/11.2.0.4/gridhome_1/network/admin/listener.ora

    echo "+++reconfigure grid"
    $ORACLE_HOME/perl/bin/perl -I $ORACLE_HOME/perl/lib -I $ORACLE_HOME/crs/install $ORACLE_HOME/crs/install/roothas.pl

    # script to be run as oracle user
    cat > /tmp/oracle_reconfig.sh << 'EOF'
        #!/bin/bash
        source oraenv <<< +ASM
        srvctl add listener
        # get spfile for ASM
        spfile=$(adrci exec="set home +asm ; show alert -tail 1000" | grep -oE -m 1 '\+ORADATA.*')
        srvctl add asm -l LISTENER -p "$spfile" -d "ORCL:ORA*"
        crsctl modify resource "ora.asm" -attr "AUTO_START=1"
        crsctl modify resource "ora.cssd" -attr "AUTO_START=1"
        crsctl stop has
        crsctl enable has
        crsctl start has
        sleep 10
        i=0
        asm_status=$(srvctl status asm | grep "ASM is running")
        if [[ -z "$asm_status" ]]; then
            if [[ "$i" == '10' ]]; then
                echo "ASM did not start after 5 minutes, resize oracle asm disks manually"
                break
            fi
            sleep 30
            asm_status=$(srvctl status asm | grep "ASM is running")
            ((i++))
        fi
        sqlplus -s / as sysasm <<< "alter diskgroup ORADATA resize all;"
EOF

    # run the script as oracle user
    chown oracle:oinstall /tmp/oracle_reconfig.sh
    chmod u+x /tmp/oracle_reconfig.sh
    echo "+++running reconfiguration script as oracle user"
    su - oracle -c /tmp/oracle_reconfig.sh

}

main() {
    hugepages
    swap_disk
    disks
    reconfigure_oracle_has
}

main