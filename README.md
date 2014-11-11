Phantom tool for mannage docker container network by using Open vSwitch
===============================
Docker networking is fast evolving. There are many options today for
using Linux bridge, port mapping, Open vSwitch for this purpose. We
found the need to have a comprehensive mechanism to network all
applications across hosts with isolation through overlay networking.

The phantom software package allows configuring the networking of individual
containers and isolating the network of container groups (i.e., pods).
The toolkit uses [Open vSwitch](http://openvswitch.org) to provide
connectivity to containers and creates GRE or VxLAN tunnels to allow containers
on different hosts to communicate with each other.

# Running
you can run the following commands to manage the networks. The toolkit 
creates virtual networks for each pod (i.e., groups of containers that
are allowed to reach each other, they are within the same VXLAN). Containers 
will not be able to communicate across pods.

* Prepare host for container networking
```
$ ph init
```
This command could simply be added to the /etc/rc.local of your host

* Connect localhost to remote hosts in cluster
```
$ ph cluster <list of remote_host_ips>
```
This command needs to be run on every hosts today. But, soon
we update code to allow entering this one a single host.

* Connect container to global pod
```
$ ph connect <container id/name> <desired_ip/mask> <pod_number>
```
This creates a new interface eth1 for the container. This is private
for cross-contain communication and cannot be used to access external
networks.

* Optionally, you can cleanup host configs after container networking
```
$ ph cleanup
```
