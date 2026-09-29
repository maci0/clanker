// Vanilla, no bundler. Instance / peers status helpers.
import { plural } from "./utils.js";

function showChip(node, on) {
  if (!node) { return; }

  node.hidden = !on;

  if (on) { node.removeAttribute("aria-hidden"); }
  else { node.setAttribute("aria-hidden", "true"); }
}

export function renderStatusInto(status, els) {
  if (!status) {
    els.instanceChip.textContent = "disconnected";
    els.instanceChip.dataset.state = "down";
    showChip(els.instanceChip, true);
    showChip(els.peersChip, false);
    els.instance.textContent = "unreachable (is `clanker serve` still running?)";
    els.peers.textContent = "unknown";

    return { instanceName: "", knownPeers: [] };
  }

  var peers = status.peers || [];
  var instanceName = status.instance.name;
  els.instanceChip.textContent = status.instance.name;
  els.instanceChip.dataset.state = "live";
  showChip(els.instanceChip, true);
  showChip(els.peersChip, peers.length > 0);
  els.peersChip.textContent = plural(peers.length, { one: "peer", other: "peers" });
  els.instance.textContent = status.instance.name + " (" + status.instance.id + ")";
  els.peers.textContent = "";

  if (peers.length === 0) {
    els.peers.textContent = "none configured";

    return { instanceName, knownPeers: peers };
  }

  var list = document.createElement("ul");
  peers.forEach(function (p) {
    var item = document.createElement("li");
    var name = document.createElement("b");
    name.textContent = p.name;
    item.appendChild(name);
    item.appendChild(document.createTextNode(": "));

    if (/^https?:\/\//i.test(p.url)) {
      var link = document.createElement("a");
      link.href = p.url;
      link.textContent = p.url;
      item.appendChild(link);
    } else {
      item.appendChild(document.createTextNode(p.url));
    }

    list.appendChild(item);
  });
  els.peers.appendChild(list);

  return { instanceName, knownPeers: peers };
}
