# dmgbuild settings for MLX Node's disk image (0.9.8+), used by .github/workflows/mac-app.yml:
#   dmgbuild -s mac/DiskImage/settings.py -D app="<path>/MLX Node.app" -D background=<dir>/background.png "MLX Node" MLX-Node-098.dmg
#
# The disk image holds only "MLX Node.app" (visible, at the top, this exact name: every installed MLX Node's in-app
# updater looks for a non-hidden *.app with bundle id app.mlx.mac there). No Applications shortcut: MLX Node opened
# from the image installs itself (MLX/UI/InstallView.swift). The window shows the app over a background saying
# "Open MLX Node to install" (background.png + background@2x.png from background.swift; dmgbuild joins them).
import os

app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {}

# the volume icon: the app's own
_icns = os.path.join(app, "Contents", "Resources", "AppIcon.icns")
icon = _icns if os.path.isfile(_icns) else None

_bg = defines.get("background")  # noqa: F821
background = _bg if _bg and os.path.isfile(_bg) else None

# window: 560 × 400 points (the background is drawn for that; whether Finder counts the title bar or not, the
# part that may be cut off at the bottom is plain), nothing but the icon view
window_rect = ((200, 140), (560, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
label_pos = "bottom"
text_size = 13
icon_size = 128
# centre of the icon, in the window's points from the top left (background.swift draws around this point)
icon_locations = {_name: (280, 150)}
