import 'node_host_fs.dart' as node;

typedef HostTemp = node.NodeHostTemp;

HostTemp? createHostTemp(String prefix) => node.createNodeHostTemp(prefix);
