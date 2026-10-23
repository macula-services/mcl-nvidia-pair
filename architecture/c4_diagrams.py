"""Generate mcl-nvidia-pair's three C4 diagrams into assets/.

Run:  python3 architecture/c4_diagrams.py

  c4-context.svg     Level 1: the bridge and who it deals with
  c4-containers.svg  Level 2: the bridge on its box, beside PAIR
  c4-components.svg  Level 3: inside the service

Every box and arrow is taken from the code on this branch: the capability
mcl_nvidia_pair_service advertises and its auth policy, what
mcl_nvidia_pair_mesh_rpc does per call, the limiter, the one outbound request
chat_to_pair builds, the ports the Containerfile exposes and the environment
variables config/sys.config.src reads. When the code changes, change this file
and re-run it; a diagram that names something the release lost is drift.

Colours are plain classes with a prefers-color-scheme: dark block, no CSS
custom properties (rsvg-convert renders those black), so the SVGs render the
same on GitHub, in IDE previews and through rsvg-convert. After a change,
render each (rsvg-convert -w 1400 assets/c4-context.svg -o /tmp/c.png) and
look at it; keep architecture/README.md in step. The drawing code is
mcl-distributor's (architecture/c4_diagrams.py there), which is mcl-jobs'.
"""
import os
from xml.sax.saxutils import escape

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets")

SANS = '"Atkinson Hyperlegible", "Segoe UI", system-ui, -apple-system, Helvetica, Arial, sans-serif'
MONO = '"JetBrains Mono", ui-monospace, Menlo, Consolas, monospace'

# Element kinds, each (light fill, light stroke, dark fill, dark stroke).
KINDS = {
    "b-sys": ("#F5E9CC", "#A56F0A", "#3A2E13", "#E3AA3C"),   # in scope
    "b-per": ("#E3EBF2", "#3B5B7A", "#1D2A36", "#8EB4D8"),   # person
    "b-mac": ("#E6E4EE", "#5E5A78", "#26243A", "#A9A4C8"),   # Macula infrastructure
    "b-ext": ("#ECEFED", "#8A9791", "#1C2421", "#7D8B85"),   # external system
    "b-cmp": ("#FFFFFF", "#8A9791", "#171F1C", "#7D8B85"),   # component or container
}

STYLE = f"""<style>
.t-name {{ font-family: {SANS}; font-size: 15px; font-weight: 700; }}
.t-desc {{ font-family: {SANS}; font-size: 12.5px; }}
.t-rel {{ font-family: {SANS}; font-size: 11.5px; paint-order: stroke; stroke-width: 4px; stroke-linejoin: round; }}
.t-code {{ font-family: {MONO}; font-size: 13px; font-weight: 600; }}
.t-type {{ font-family: {MONO}; font-size: 11.5px; }}
.t-bound {{ font-family: {MONO}; font-size: 12px; font-weight: 600; }}
.t-leg {{ font-family: {SANS}; font-size: 12px; }}
.edge {{ fill: none; stroke-width: 1.25; }}
.edge-later {{ fill: none; stroke-width: 1.25; stroke-dasharray: 5 4; }}
.bg {{ fill: #FFFFFF; }}
""" + "".join(f".{k} {{ fill: {v[0]}; stroke: {v[1]}; stroke-width: {2 if k == 'b-sys' else 1.25}; }}\n" for k, v in KINDS.items()) + """\
.b-later { fill: none; stroke: #8A9791; stroke-width: 1.25; stroke-dasharray: 5 4; }
.bound { fill: none; stroke: #B3BDB8; stroke-width: 1; }
.head { fill: #3B5B7A; }
.t-name, .t-code { fill: #16201D; }
.t-type, .t-bound, .t-leg { fill: #66736E; }
.t-desc { fill: #34413C; }
.t-rel { fill: #66736E; stroke: #FFFFFF; }
.edge, .edge-later { stroke: #8A9791; }
.arrowhead { fill: #8A9791; }
@media (prefers-color-scheme: dark) {
.bg { fill: #171F1C; }
""" + "".join(f".{k} {{ fill: {v[2]}; stroke: {v[3]}; }}\n" for k, v in KINDS.items()) + """\
.b-later { stroke: #7D8B85; }
.bound { stroke: #4A5752; }
.head { fill: #8EB4D8; }
.t-name, .t-code { fill: #E6ECE9; }
.t-type, .t-bound, .t-leg { fill: #93A09A; }
.t-desc { fill: #C3CDC8; }
.t-rel { fill: #93A09A; stroke: #171F1C; }
.edge, .edge-later { stroke: #7D8B85; }
.arrowhead { fill: #7D8B85; }
}
</style>"""

DEFS = ('<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
        'orient="auto-start-reverse"><path class="arrowhead" d="M0 0L10 5L0 10z"/></marker></defs>')

LEGEND = [("b-sys", "In scope"), ("b-per", "Person"), ("b-mac", "Macula infrastructure"),
          ("b-ext", "External system"), ("b-cmp", "Container or component"), ("b-later", "Planned, not built")]
BOUNDARY = ("bound", "Boundary")


class Diagram:
    def __init__(self, name, title, w, h):
        self.name, self.title, self.w, self.h, self.parts = name, title, w, h, []

    def text(self, cls, x, y, s, anchor=None, rotate=None):
        a = f' text-anchor="{anchor}"' if anchor else ""
        r = f' transform="rotate({rotate} {x} {y})"' if rotate is not None else ""
        self.parts.append(f'<text class="{cls}" x="{x}" y="{y}"{a}{r}>{escape(s)}</text>')

    def box(self, cls, x, y, w, h, name, kind, desc, person=False, code=False):
        self.parts.append(f'<rect class="{cls}" x="{x}" y="{y}" width="{w}" height="{h}" rx="10"/>')
        tx = x + 16
        if person:
            self.parts.append(f'<circle class="head" cx="{x + 26}" cy="{y + 24}" r="9"/>')
            tx = x + 44
        self.text("t-code" if code else "t-name", tx, y + 28, name)
        self.text("t-type", tx, y + 46, kind)
        for i, line in enumerate(desc):
            self.text("t-desc", x + 16, y + 70 + 16 * i, line)

    def bound(self, x, y, w, h, label):
        self.parts.append(f'<rect class="bound" x="{x}" y="{y}" width="{w}" height="{h}" rx="12"/>')
        self.text("t-bound", x + 16, y + 22, label)

    def edge(self, d, later=False):
        self.parts.append(f'<path class="{"edge-later" if later else "edge"}" d="{d}" marker-end="url(#a)"/>')

    def legend(self, y, boundary=True):
        x = 24
        for cls, label in LEGEND + ([BOUNDARY] if boundary else []):
            self.parts.append(f'<rect class="{cls}" x="{x}" y="{y}" width="22" height="14" rx="3"/>')
            self.text("t-leg", x + 30, y + 12, label)
            x += 34 + 6.6 * len(label)

    def write(self):
        svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" role="img" '
               f'aria-label="{escape(self.title)}">', f"<title>{escape(self.title)}</title>", STYLE, DEFS,
               f'<rect class="bg" x="0" y="0" width="{self.w}" height="{self.h}"/>'] + self.parts + ["</svg>", ""]
        with open(os.path.join(OUT, self.name), "w") as f:
            f.write("\n".join(svg))




def context():
    d = Diagram("c4-context.svg", "mcl-nvidia-pair system context", 1000, 560)
    d.box("b-per", 40, 30, 270, 96, "Realm member", "[Person]",
          ["Calls chat from anywhere,", "with a membership UCAN"], person=True)
    d.box("b-mac", 690, 30, 270, 110, "macula-realm", "[Macula infrastructure]",
          ["Issues the member UCAN the gate", "checks offline, and the delegation", "that authorises this service"])
    d.box("b-sys", 365, 190, 270, 130, "mcl-nvidia-pair", "[mcl_om mesh service]",
          ["One procedure: mcl-nvidia-pair/chat,", "members only. Builds its own request;",
           "relays no path and no admin call"])
    d.box("b-ext", 40, 210, 270, 96, "PAIR Ollama facade", "[External system]",
          ["Ollama- and OpenAI-compatible", "HTTP on this host, adopted engines"])
    d.box("b-ext", 690, 200, 270, 120, "PAIR cluster", "[External system]",
          ["The household's own machines;", "PAIR routes, schedules and fails", "over inside it, unchanged"])
    d.box("b-mac", 365, 400, 270, 110, "Macula mesh", "[Macula infrastructure]",
          ["Stations carry the call; the DHT", "carries the advertisement members", "resolve"])
    d.edge("M175 126V160H420V190"); d.text("t-rel", 300, 152, "chat, member UCAN", anchor="middle")
    d.edge("M825 140V160H580V190"); d.text("t-rel", 720, 152, "admission, UCAN", anchor="middle")
    d.edge("M365 255H310"); d.text("t-rel", 337, 246, "loopback", anchor="middle"); d.text("t-rel", 337, 272, "HTTP", anchor="middle")
    d.edge("M175 306V365H880V320"); d.text("t-rel", 528, 356, "engines, on the household's machines")
    d.edge("M500 320V400"); d.text("t-rel", 508, 366, "advertises, answers")
    d.legend(530, boundary=False)
    d.write()


def containers():
    d = Diagram("c4-containers.svg", "mcl-nvidia-pair containers", 1000, 520)
    d.bound(24, 40, 620, 420, "The box beside PAIR [OCI image, host networking]")
    d.box("b-sys", 44, 76, 580, 120, "mcl-nvidia-pair service", "[mcl_om mesh service, OTP 28 release, /health on 8499]",
          ["Boots as an mcl_om service: identity key, realm admission, a mesh pool, its",
           "one capability and /health. Host networking is not a shortcut: the stations",
           "are reachable over IPv6 only, and the container reaches PAIR on 127.0.0.1."])
    d.box("b-cmp", 44, 220, 580, 96, "Identity key", "[Volume /etc/mcl/secrets]",
          ["The node's own key, generated on first boot and loaded on every boot after:",
           "the node id the realm's Providers desk admits. A fresh volume is a new service."])
    d.box("b-cmp", 44, 340, 580, 84, "/health", "[TCP 8499]",
          ["PAIR answers, the service is configured, the realm granted the procedure."])
    d.box("b-ext", 690, 76, 286, 110, "PAIR, this host", "[External system]",
          ["Ollama facade 127.0.0.1:11435", "(11434 when no local Ollama),", "OpenAI facade on :8080"])
    d.box("b-mac", 690, 220, 286, 96, "Macula mesh", "[Macula infrastructure]",
          ["Pinned stations, QUIC"])
    d.box("b-mac", 690, 340, 286, 84, "ghcr.io", "[External system]",
          ["The signed image, pinned by digest", "in the fleet repository"])
    d.edge("M624 140H690"); d.text("t-rel", 657, 132, "loopback HTTP", anchor="middle")
    d.edge("M624 260H660V300H690"); d.text("t-rel", 668, 276, "joins", anchor="middle", rotate=-90)
    d.edge("M690 382H644V186H624"); d.text("t-rel", 652, 330, "pulled from", anchor="middle", rotate=-90)
    d.edge("M184 196V220"); d.text("t-rel", 192, 212, "reads")
    d.legend(490)
    d.write()


def components():
    d = Diagram("c4-components.svg", "mcl-nvidia-pair components", 1000, 620)
    d.bound(16, 40, 968, 520, "mcl-nvidia-pair service [Container]")
    d.box("b-cmp", 32, 70, 456, 120, "mcl_nvidia_pair_service", "[mcl_om_service module]",
          ["One capability, chat, with auth realm_member_required over the realm key's",
           "id and required_can (member/email-verified by default). Announces nothing",
           "without a realm key: this forwards onto someone's own hardware."], code=True)
    d.box("b-cmp", 512, 70, 456, 120, "mcl_nvidia_pair_mesh_rpc", "[macula_response handler]",
          ["Per call: fold the payload to one shape, take the wire-authenticated",
           "caller, ask the limiter, forward. Macula verified the UCAN before this",
           "ran, so no token is parsed here."], code=True)
    d.box("b-sys", 32, 220, 456, 130, "throttle_pair_callers", "[gen_server, ets]",
          ["Fixed window per caller, atomic ets:update_counter: a rejected call still",
           "counts. max_per_window and window_seconds come from the environment",
           "(PAIR_MAX_PER_WINDOW, PAIR_WINDOW_SECONDS), shipped at 20 per 60 s."], code=True)
    d.box("b-sys", 512, 220, 456, 130, "chat_to_pair", "[module, httpc]",
          ["Builds the outbound request itself (POST <facade>/v1/chat/completions)",
           "and parses choices[0].message.content. probe/0 is /v1/models, for /health.",
           "No caller-supplied path, method or header is ever relayed."], code=True)
    d.box("b-cmp", 32, 390, 456, 110, "mcl_nvidia_pair_sup", "[supervisor]",
          ["One permanent child: the limiter. Health is health_of/2 over the",
           "capabilities and the PAIR probe, so an unconfigured bridge reads",
           "degraded rather than healthy."], code=True)
    d.box("b-ext", 512, 390, 456, 110, "PAIR proxy", "[External system]",
          ["127.0.0.1:11435 over plain loopback HTTP:", "the same interface PAIR gives every consumer",
           "on that machine."], code=True)
    d.edge("M740 190V220"); d.text("t-rel", 748, 210, "allow/1")
    d.edge("M488 285H512"); d.text("t-rel", 500, 276, "chat/3", anchor="middle")
    d.edge("M740 350V390"); d.text("t-rel", 748, 374, "HTTP")
    d.edge("M260 500V520"); d.text("t-rel", 268, 512, "supervises")
    d.legend(590)
    d.write()


if __name__ == "__main__":
    for make in (context, containers, components):
        make()
