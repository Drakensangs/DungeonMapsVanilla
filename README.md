# 🏰🗺️ **DungeonMapsVanilla** (Vanilla 1.12.1)

> [!IMPORTANT]
> **DungeonMapsVanilla** requires [**ClassicAPI**](https://github.com/brues-code/ClassicAPI) in order to function.

DungeonMapsVanilla is an addon that adds functional dungeon & raid maps to the game's world map with the following features:

 - functional player arrow
 - toggleable party/raid member blips
 - working floor transitions
 - WotLK style Areas dropdown menu to switch between floors
 - toggleable boss, quest, loot & object markers that can be repositioned or removed in-game
 - toggleable Dungeon Markers dropdown menu
 - toggleable player/mouse coordinates in dungeons & raids
 - dungeons & raids integrated into the default world map Continent and Zone dropdown menus
 - options menu integrated into ClassicAPI's Addon Options interface
 - [**Atlas**](https://warperia.com/addon-vanilla/atlasloot-enhanced/) & [**AtlasLoot**](https://warperia.com/addon-vanilla/atlasloot-enhanced/) compatibility; clicking markers will open Atlas on the appropriate page
 - [**Magnify**](https://github.com/paokkerkir/Magnify) compatibility
 - [**pfUI**](https://github.com/brues-code/pfUI) compatibility; skins the dropdown menus and defers to pfUI when it comes to the world map size

I tried making the zone transitions as solid as possible for the most part, but if you encounter any situations where the floors fail to switch properly, please report where the failures occurred.

Regarding compatibility, I haven't tested any world map altering addons other than pfUI and ShaguTweaks, so if there are any issues, please report them. Also, if you're using ShaguTweaks, there's not much reason to use its WorldMap Window module, since DMV has its own world map slider feature.

## Known Limitations

 - party/raid member blips disappear if there's a distance of over 100 yards or so between you and them
 - party/raid member blips will will show between dungeon/raid floors, so for example if you're on floor 1 of a dungeon and the rest of your party is on floor 2, you'll see their positions bleeding into your floor; tried working around this, but I just couldn't find a 100% solid fix for it
 - if your game or system crashes while you're inside a dungeon, the addon won't be able to save your last known floor location; this can be easily fixed by opening the Areas dropdown menu and shift clicking the floor you're on

## 👨‍💻 **Author**

Drakensangs

## 📜 **Credits**
 - addon inspired by [**WDM**](https://github.com/Trimitor/WDM-patch) & [**SimpleDungeonMap**](https://www.curseforge.com/wow/addons/simpledungeonmap)
 - dungeon & raid maps from [**WDM**](https://github.com/Trimitor/WDM-patch) & a few map tiles from TurtleWoW
 - party/raid member blips & quest, loot, object marker assets from [**ShaguTweaks**](https://github.com/shagu/ShaguTweaks)
 - boss marker asset from [**ModernMapMarkers**](https://github.com/Drakensangs/ModernMapMarkers-Vanilla)

## 🎥 **Video Demonstration**

[![IMAGE ALT TEXT HERE](https://img.youtube.com/vi/yE8CymfyHdw/0.jpg)](https://www.youtube.com/watch?v=yE8CymfyHdw)

## 📸 **Screenshots**

<img width="1917" height="1438" alt="dmv1" src="https://github.com/user-attachments/assets/6a461979-b4d5-4066-bbcd-b4ff0fc5aeee" />
<img width="1911" height="1440" alt="dmv2" src="https://github.com/user-attachments/assets/ac59a81a-ee3e-4351-8a81-7a19802efd66" />
<img width="1912" height="1436" alt="dmv3" src="https://github.com/user-attachments/assets/4a556c0a-d4e7-4522-b43e-2abd162bee10" />
<img width="1912" height="1439" alt="dmv4" src="https://github.com/user-attachments/assets/961997ad-28ee-4654-9bc8-9a392fec4779" />
<img width="1912" height="1439" alt="dmv5" src="https://github.com/user-attachments/assets/231fae37-0321-49c5-9795-9a5f302b8ab4" />
<img width="1911" height="1440" alt="dmv6" src="https://github.com/user-attachments/assets/71df1362-0ba4-4eac-a23e-62f039bfff5b" />
<img width="1913" height="1436" alt="dmv7" src="https://github.com/user-attachments/assets/9f6dcf46-2130-46a0-81bc-f09170ada7b1" />
<img width="1914" height="1439" alt="dmv8" src="https://github.com/user-attachments/assets/a3862a50-6fda-49d7-a28b-4e71e7707620" />
<img width="1588" height="1160" alt="dmv9" src="https://github.com/user-attachments/assets/a9c49534-9053-49a9-8a39-5ebd1a37f566" />
<img width="1010" height="899" alt="dmv10" src="https://github.com/user-attachments/assets/741e1e74-fdb2-4872-8a75-d314dc611a7f" />
