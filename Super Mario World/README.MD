# Super Mario World

This directory contains the patch to enable the Cx4 co-processor in Super Mario World.

## Usage

1. Download the latest version of asar and Lunar Magic manually.
2. Place your backup copy of Super Mario World in this directory.
3. (Optional step) Using Lunar Magic, apply the FastROM patch and addressing mode.
4. Using Lunar Magic, expand the ROM to 2MB. This is the maximum size physically allowed by the Cx4 chip.
5. Apply the Cx4 patch using asar*. There is a batch file included to do this.

* Asar v2 is in active development and there is currently no public build with an `arch cx4`. I will contribute my changes to the repository in the near future.
