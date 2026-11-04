"""Write Finder layout directly, without depending on Finder's delayed preference flush."""
import sys
from pathlib import Path
from ds_store import DSStore
from mac_alias import Alias
root = Path(sys.argv[1])
with DSStore.open(str(root / '.DS_Store'), 'w+') as store:
    store['.']['bwsp'] = {
        'ShowStatusBar': False, 'ShowToolbar': False, 'ShowTabView': False,
        'ShowPathbar': False, 'ShowSidebar': False, 'SidebarWidth': 0,
        'WindowBounds': '{{200, 200}, {640, 550}}',
    }
    store['.']['icvp'] = {
        'viewOptionsVersion': 1, 'backgroundType': 2,
        'backgroundColorRed': 1.0, 'backgroundColorGreen': 1.0, 'backgroundColorBlue': 1.0,
        'scrollPositionX': 0.0, 'scrollPositionY': 0.0,
        'backgroundImageAlias': Alias.for_file(str(root / '.background/background.png')).to_bytes(),
        'iconSize': 80.0, 'textSize': 13.0, 'gridSpacing': 100.0,
        'gridOffsetX': 0.0, 'gridOffsetY': 0.0, 'arrangeBy': 'none',
        'labelOnBottom': True, 'showItemInfo': False, 'showIconPreview': True,
    }
    store['.']['vSrn'] = ('long', 1)
    store['.']['icvl'] = ('type', 'icnv')
    store['Wupsy.app']['Iloc'] = (165, 130)
    store['Applications']['Iloc'] = (475, 130)
