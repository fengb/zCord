# zigbot9001

Discord Bot written in Zig that provides:

- GitHub issue lookup on the Zig repository
- Zig standard library search using [analysis-buddy](https://github.com/alexnask/analysis-buddy)
- funny commands

## building

```
git clone --recursive https://github.com/fengb/zigbot9001
cd zigbot9001

zig build

# might need to build using this
# see https://github.com/ziglang/zig/issues/6036#issuecomment-672446525
zig build -Dtarget=x86_64-linux-gnu.2.25
```

## running

```
# edit run.sh with your credentials and zig library path
# then run it
./run.sh
```
