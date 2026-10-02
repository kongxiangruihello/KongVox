"""Write the Finder window layout; requires ds_store==1.3.1 and mac-alias==2.2.2."""
import sys
from pathlib import Path
from ds_store import DSStore
from mac_alias import Alias, Bookmark
root = Path(sys.argv[1]).resolve()
alias = Alias.for_file(str(root / '.background' / 'installer.png')).to_bytes()
with DSStore.open(str(root / '.DS_Store'), 'w+') as store:
    store['.']['bwsp'] = dict(ShowStatusBar=False, ShowToolbar=False, ShowPathbar=False,
        ShowSidebar=False, ContainerShowSidebar=False, WindowBounds='{{160, 160}, {660, 430}}')
    store['.']['icvp'] = dict(viewOptionsVersion=1, backgroundType=2, backgroundImageAlias=alias,
        backgroundColorRed=1.0, backgroundColorGreen=1.0, backgroundColorBlue=1.0,
        scrollPositionX=0.0, scrollPositionY=0.0, iconSize=104.0, textSize=13.0, labelOnBottom=True, showItemInfo=False,
        showIconPreview=True, arrangeBy='none', gridSpacing=80.0, gridOffsetX=0.0, gridOffsetY=0.0)
    store['.']['pBBk'] = Bookmark.for_file(str(root / '.background' / 'installer.png'))
    store['.']['vSrn'] = ('long', 1)
    store['.']['icvl'] = ('type', b'icnv')
    store['.']['vstl'] = ('type', b'icnv')
    store['KongVox.app']['Iloc'] = (180, 205)
    store['Applications']['Iloc'] = (480, 205)
