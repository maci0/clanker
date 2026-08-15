// Vanilla, no bundler. Instance / peers status helpers.
import { upgradePfChip } from "./ui.js";

function showChip(node, on) {
  if (!node) return;
  node.hidden = !on;
  if (on) node.removeAttribute("aria-hidden");
  else node.setAttribute("aria-hidden", "true");
}

export function renderStatusInto(status, els, readOnly) {
  if (!status) {
    els.instanceChip.textContent = "disconnected";
    els.instanceChip.dataset.state = "down";
    upgradePfChip(els.instanceChip);
    showChip(els.instanceChip, true);
    showChip(els.peersChip, false);
    els.instance.textContent = "unreachable (is `clanker serve` still running?)";
    els.peers.textContent = "unknown";
    return { instanceName: "", knownPeers: [] };
  }
  var peers = status.peers || [];
  var instanceName = status.instance.name;
  var knownPeers = peers;
  els.instanceChip.textContent = status.instance.name;
  els.instanceChip.dataset.state = "live";
  upgradePfChip(els.instanceChip);
  showChip(els.instanceChip, true);
  showChip(els.peersChip, peers.length > 0);
  els.peersChip.textContent = peers.length + (peers.length === 1 ? " peer" : " peers");
  upgradePfChip(els.peersChip);
  els.instance.textContent = status.instance.name + " (" + status.instance.id + ")";
  els.peers.textContent = "";
  if (peers.length === 0) {
    els.peers.textContent = "none configured";
    return { instanceName: instanceName, knownPeers: knownPeers };
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
  return { instanceName: instanceName, knownPeers: knownPeers };
}
