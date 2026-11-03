"""dmgbuild writes this Finder layout directly, without AppleScript."""
from pathlib import Path

app = defines["app"]
format = "UDZO"
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
icon_locations = {Path(app).name: (180, 180), "Applications": (460, 180)}
window_rect = ((200, 200), (640, 360))
default_view = "icon-view"
background = "#f5f5f7"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 14
include_icon_view_settings = True
