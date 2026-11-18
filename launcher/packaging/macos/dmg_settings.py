# dmgbuild settings for ThousandRealms.dmg (build_app.sh passes the -D values).
import os.path

app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
readme = defines.get("readme", "")  # noqa: F821
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]  # noqa: F821
background = defines["background"]  # noqa: F821
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0
window_rect = ((200, 120), (660, 420))
default_view = "icon-view"
show_icon_preview = False
arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 13
icon_size = 112
icon_locations = {app_name: (170, 190), "Applications": (490, 190)}
hide_extensions = [app_name]
if readme:
    files.append(readme)
    icon_locations[os.path.basename(readme)] = (330, 335)
