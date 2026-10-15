# scripts

A collection of small, handy scripts for everyday development tasks.

Each script is self-contained. Run it from a terminal, and it either asks for what it needs or describes itself in the comments at the top of the file.

## Scripts

| Script | What it does |
| --- | --- |
| [delete-branches.sh](delete-branches.sh) | Interactively delete local or remote git branches. You pick the repo, choose local or remote, select branches from a list, then review and confirm. Protected branches (`main`, `master`, `develop`) and the branch you have checked out are never offered. |

## Usage

```bash
git clone <this-repo-url> ~/scripts
cd ~/scripts
./delete-branches.sh
```

Tip: add the folder to your `PATH` to run the scripts from anywhere:

```bash
echo 'export PATH="$HOME/scripts:$PATH"' >> ~/.zshrc
```

## Adding a script

- Make it executable (`chmod +x`) and start it with a short comment explaining what it does.
- Add a row to the table above.
