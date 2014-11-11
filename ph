#!/bin/bash
set -ex

CONTAINER_INTERFACE=eth1
DEFAULT_MASK=24
TUNNEL_TYPE=vxlan
BR_INT=br0
BR_TUN=br1

# Function to create two bridges on the host connected to each other
f_create_bridges_with_default_flows() {
    #in case /var/run/netns not exist
    sudo mkdir -p /var/run/netns
    iptables -I INPUT -p udp --dport 4789 -j ACCEPT
    ovs-vsctl add-br $BR_INT
    ovs-vsctl add-br $BR_TUN
    ovs-vsctl set-manager pssl:6640
    ovs-vsctl set-controller $BR_TUN tcp:6633
    ovs-vsctl set bridge $BR_TUN protocols=OpenFlow13
    ovs-vsctl add-port $BR_INT patch-tun -- set interface patch-tun type=patch options:peer=patch-int
    ovs-vsctl set port patch-tun vlan_mode=trunk
    ovs-vsctl add-port $BR_TUN patch-int -- set interface patch-int type=patch options:peer=patch-tun
    ovs-vsctl set port patch-int vlan_mode=trunk

    PATCH_INT_PORT=`ovs-ofctl -OOpenFlow13 dump-ports-desc $BR_TUN | grep patch-int | awk -F '(' '{ print $1 }'`

    # Traffic from $BR_INT is sent to table 20 (unicast) or table 21 (multicast)
    ovs-ofctl -OOpenFlow13 add-flow $BR_TUN "table=0,priority=1,in_port=$PATCH_INT_PORT,dl_dst=00:00:00:00:00:00/01:00:00:00:00:00 actions=resubmit(,20)"
    ovs-ofctl -OOpenFlow13 add-flow $BR_TUN "table=0,priority=1,in_port=$PATCH_INT_PORT,dl_dst=01:00:00:00:00:00/01:00:00:00:00:00 actions=resubmit(,21)"

    # Rule for learning Src MAC of traffic incoming from GRE Tunnel
    ovs-ofctl -OOpenFlow13 add-flow $BR_TUN "table=10,priority=1,actions=learn(table=20,hard_timeout=300,priority=1,\
                NXM_OF_VLAN_TCI[0..11],NXM_OF_ETH_DST[]=NXM_OF_ETH_SRC[],\
                load:0->NXM_OF_VLAN_TCI[],load:NXM_NX_TUN_ID[]->NXM_NX_TUN_ID[],\
                output:NXM_OF_IN_PORT[]),$PATCH_INT_PORT"

    # Rule for multicasting unknown unicast traffic from $BR_INT
    ovs-ofctl -OOpenFlow13 add-flow $BR_TUN "table=20,priority=0 actions=resubmit(,21)"

    # Default drop for invalid tunnel traffic and all unknown port traffic
    ovs-ofctl -OOpenFlow13 add-flow $BR_TUN "table=0,priority=0,actions=resubmit(,3)"
    ovs-ofctl -OOpenFlow13 add-flow $BR_TUN table=3,priority=0,actions=drop
    ovs-ofctl -OOpenFlow13 add-flow $BR_TUN table=21,priority=0,actions=drop

    # Enumerated list of output actions to use for multicasting
    ovs-ofctl -O OpenFlow13 add-flow $BR_TUN table=22,priority=0,actions=drop
}

#Function to create VXLAN tunnel and the appropriate flood rules for oVS
f_create_tunnel() {
    # Ensure that the VXLAN port has been set to match on its key
    for REMOTE_IP in $@
    do
        echo "Connecting localhost to remote host $REMOTE_IP"
        PORT_NAME="$TUNNEL_TYPE`printf '%02x' ${REMOTE_IP//./ }`"
        ovs-vsctl add-port $BR_TUN $PORT_NAME -- set interface $PORT_NAME type=$TUNNEL_TYPE options:remote_ip=$REMOTE_IP options:in_key=flow options:out_key=flow
    done

    #TUN_PORT=`ovs-ofctl -OOpenFlow13 dump-ports-desc $BR_TUN | grep $PORT_NAME | awk -F '(' '{ print $1 }'`

    # Recreate multicast group
    GROUP_ACTIONS=""
    for EACH_TUN_PORT in `ovs-ofctl -OOpenFlow13 dump-ports-desc $BR_TUN | grep -P "$TUNNEL_TYPE.*addr" | awk -F '(' '{ print $1 }'`
    do
    GROUP_ACTIONS="${GROUP_ACTIONS}output:$EACH_TUN_PORT,"
    done
    ovs-ofctl -O OpenFlow13 add-flow $BR_TUN table=22,priority=1,actions=$GROUP_ACTIONS
}

f_connect_container() {
        CONTAINER=$1
        IP_ADDR=$2
        POD_ID=$3

    pid=`docker inspect --format '{{ .State.Pid }}' $CONTAINER`
    ln -s /proc/$pid/ns/net /var/run/netns/$pid
    ip link add tap$pid type veth peer name peertap$pid
    ifconfig tap$pid up
    ifconfig peertap$pid up
    ip link set peertap$pid netns $pid
    ip netns exec $pid ip link set dev peertap$pid name $CONTAINER_INTERFACE
    ip netns exec $pid ip link set $CONTAINER_INTERFACE up

    # Add subnet mask of DEFAULT_MASK if it is missing
    if ! echo $IP_ADDR | grep -q "/"; then
        IP_ADDR="$IP_ADDR/$DEFAULT_MASK"
    fi
    ip netns exec $pid ip addr add "${IP_ADDR}" dev $CONTAINER_INTERFACE
   
    # do not set the default gw  
    #ip netns exec $pid ip route add default via `echo $IP_ADDR | awk -F '.' '{ print $1 "." $2 "." $3 "." 1 }'`
    ovs-vsctl add-port $BR_INT tap$pid -- set port tap$pid tag=$POD_ID

    VLAN_ID=$3
    TUN_ID=$((VLAN_ID+0x10000))

    # Rule for traffic from tunnel for each container group
    ovs-ofctl -OOpenFlow13 add-flow $BR_TUN "table=3,priority=1,tun_id=$TUN_ID actions=mod_vlan_vid:$VLAN_ID,resubmit(,10)"

    # Rule for multicasting traffic to tunnels
    ovs-ofctl -OOpenFlow13 add-flow $BR_TUN "table=21,priority=1,dl_vlan=$VLAN_ID,actions=strip_vlan,set_tunnel:$TUN_ID,resubmit(,22)"
}

f_cleanup() {
    #!/bin/sh
    ovs-vsctl del-br $BR_INT
    ovs-vsctl del-br $BR_TUN
    iptables -D INPUT -p udp --dport 4789 -j ACCEPT
    find -L /var/run/netns -type l -delete
}

f_install() {
    sudo apt-get install openvswitch-controller openvswitch-switch
}


################## main ########################

case "$1" in

'init')
    echo "Initializing system for network isolation"
    f_create_bridges_with_default_flows
;;

'cluster')
    f_create_tunnel ${@:2}
;;

'connect')
    echo "Connecting Docker container $2 to pod $4"
    f_connect_container $2 $3 $4
;;

'cleanup')
    echo "Cleaning up system"
    f_cleanup 
;;

'install')
    echo "Installing the openvswitch software to the server"
    f_install
;;


'')
echo "phantom - isolate Docker pod networks"
echo "Usage: $0 (install|init|cluster|connect|cleanup)"
echo "Commands:"
echo " $0 install                                    : Install openvswitch and other essential software on ubuntu 14.04 server"
echo " $0 init                                       : Prepare system for network isolation"
echo " $0 cluster \$remote_host_ips                   : Connect localhost to specified remote hosts"
echo " $0 connect \$container \$desired_ip \$pod_number : Connect container to global pod"
echo " $0 cleanup                                    : Cleanup of system"
;;
esac

