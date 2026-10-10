# Contributing

Thanks for wanting to help. Every kind of contribution counts here: bug reports, test results on a platform we haven't tried, reverse-engineering notes, docs fixes and code. If you're unsure whether something is worth raising, raise it.

## The one hard rule

Never commit, attach or link to game files: `BEASTS.EXE` (patched or not), disc images, extracted data, music or save files. Beasts & Bumpkins is still © Worldweaver / EA. Everything the scripts generate goes into `.local/`, which is gitignored. Our own patch code (`patches/*.asm` and the assembled `.bin` files) is fine to commit.

## Reporting bugs and test results

Open an issue with:

- OS and version (and CrossOver version on macOS)
- Mission resolution, window or fullscreen
- What you did, what you expected, what happened
- A screenshot if it's visual, and anything relevant from `.local/logs/`

"It worked fine on Windows 11 at 1920x1080" is a useful report too, so please post those.

If you have a disc that isn't the English EU CD, the output of `python3 scripts/peinfo.py path/to/BEASTS.EXE` tells us how far it is from the supported version.

## Making changes

1. Fork the repo and create a branch.
2. Set up the game as described in the [README](README.md) (`prepare`, then `install`).
3. Make your change. For the x86 patches, edit `patches/*.asm` and rebuild with [nasm](https://www.nasm.us/):

   ```sh
   python3 scripts/bbpatch.py assemble
   python3 scripts/bb.py install --resolution 1280x720
   python3 scripts/bb.py run
   ```

4. Test the change in game. For anything touching display or HUD code, check at least 640x480 and one wide resolution, in both window and fullscreen.
5. Commit the `.asm` and the rebuilt `.bin` together, using [Conventional Commits](https://www.conventionalcommits.org/) (`fix: ...`, `feat: ...`, `docs: ...`).
6. Open a pull request saying what changed, why, and how you tested it.

For bigger changes (new patches, new platforms, restructuring the scripts), opening an issue first to talk it through saves everyone time.

## Where to find things

- `scripts/bb.py`: main CLI (`prepare`, `install`, `run`, `stop`)
- `scripts/bbpatch.py`: verified byte patches and the patch section builder
- `patches/`: our x86 code patches (`qol.asm`, `screenmode.asm`)
- `research/`: reverse-engineering notes, addresses and how each hook works. Read these before patching; add to them when you learn something new
- `plans/`: roadmap

## Reverse engineering

The long-term goal is to understand `BEASTS.EXE` well enough to decompile and rebuild it. Findings are welcome on their own, without a patch attached: a named function, a struct layout, a file format, a note on how a game system works. Add them to `research/` (a new markdown file is fine) and cite addresses against the supported EU executable.

## Licence

By contributing you agree your work is released under the [GNU GPL v3](LICENSE), like the rest of the project.
