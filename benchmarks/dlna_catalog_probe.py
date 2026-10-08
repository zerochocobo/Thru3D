"""Read a specified LAN DLNA ContentDirectory for device video diagnostics."""
import argparse
import json
from pathlib import Path
import socket
import time
import urllib.request
from urllib.parse import urljoin, urlparse
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

TYPE = "urn:schemas-upnp-org:service:ContentDirectory:1"


def discover(host):
    packet = ('M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\n'
              'MX: 2\r\nST: '+TYPE+'\r\n\r\n').encode()
    found = []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.settimeout(.4)
        s.sendto(packet, (host, 1900)); s.sendto(packet, ("239.255.255.250", 1900))
        deadline = time.monotonic()+5
        while time.monotonic() < deadline:
            try: data, address = s.recvfrom(8192)
            except socket.timeout: continue
            if address[0] != host: continue
            for line in data.decode("utf-8", "replace").splitlines():
                if line.lower().startswith("location:"):
                    found.append(line.split(":", 1)[1].strip())
    if not found: raise RuntimeError("No SSDP response from specified server")
    return found[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--location")
    parser.add_argument("--object", default="0")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(); args.output.mkdir(parents=True, exist_ok=True)
    location = args.location or discover(args.host)
    if urlparse(location).hostname != args.host: raise RuntimeError("Unexpected DLNA host")
    description = urllib.request.urlopen(location, timeout=8).read()
    doc = ET.fromstring(description)
    child = lambda node, name: next((n.text for n in node if n.tag.split("}")[-1] == name), "")
    control = next(child(s, "controlURL") for s in doc.iter() if s.tag.split("}")[-1] == "service"
                   and child(s, "serviceType").startswith("urn:schemas-upnp-org:service:ContentDirectory:"))
    base = next((n.text for n in doc.iter() if n.tag.split("}")[-1] == "URLBase"), location)
    control = urljoin(base, control)
    body = ('<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
        '<s:Body><u:Browse xmlns:u="'+TYPE+'"><ObjectID>'+escape(args.object)+'</ObjectID>'
        '<BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter><StartingIndex>0</StartingIndex>'
        '<RequestedCount>1000</RequestedCount><SortCriteria></SortCriteria></u:Browse></s:Body></s:Envelope>').encode()
    request = urllib.request.Request(control, body, {"Content-Type": 'text/xml; charset="utf-8"', "SOAPAction": '"'+TYPE+'#Browse"'})
    answer = urllib.request.urlopen(request, timeout=20).read()
    result = next(n.text for n in ET.fromstring(answer).iter() if n.tag.split("}")[-1] == "Result")
    entries = []
    for item in ET.fromstring(result):
        entry = {"id": item.get("id"), "container": item.tag.split("}")[-1] == "container",
                 "title": child(item, "title"), "class": child(item, "class"), "resources": []}
        for res in item:
            if res.tag.split("}")[-1] == "res": entry["resources"].append(dict(res.attrib) | {"uri": res.text})
        entries.append(entry)
    report = {"location": location, "control": control, "object": args.object, "entries": entries}
    (args.output / (args.object.replace("/", "_").replace(":", "_")+"-catalog.json")).write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(report), flush=True)


if __name__ == "__main__":
    main()
