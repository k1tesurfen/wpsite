# Installing wpsite — step-by-step (no coding experience needed)

> 🇩🇪 Deutsche Version: [INSTALL.de.md](INSTALL.de.md)

This guide gets **wpsite** working on your Mac. It takes about **20–30 minutes**, and
you only do it once. Just follow the steps in order and copy-paste the commands exactly.

`wpsite` makes a safe local copy of a client's website on your own Mac, so you can test
changes and updates without touching the live site.

> Every command below goes into the **Terminal** app. "Paste" means: click in the
> Terminal window, paste the line, and press **Return**. If a command asks for a
> password, it wants **your Mac login password** (you won't see anything as you type —
> that's normal — just type it and press Return).

---

## Before you start — the checklist

You need:

1. **A Mac** (this tool is macOS only).
2. **Your Mac's admin password** (you'll type it a couple of times).
3. **Google Drive for Desktop**, signed in with your **@artismedia.de** account, with the
   shared drive **`01_Projekte`** visible in Finder.
   - Not sure? Open **Finder** → in the sidebar under *Locations* you should see **Google
     Drive**. Click it and look for **Shared drives → 01_Projekte**. If it's not there,
     install Google Drive for Desktop and sign in first, then come back.

---

## Step 1 — Open Terminal

1. Press **⌘ (Command) + Space** to open Spotlight.
2. Type **Terminal** and press **Return**.

A small window with text opens. That's where every command goes.

---

## Step 2 — Install Homebrew and the helper tools

**Homebrew** is a safe, standard installer for Mac tools. Paste this line and press Return:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

- It may ask for your Mac password, and to install "Command Line Tools" — say yes. This part
  can take several minutes. Let it finish.
- When it's done, it may print **"Next steps"** with two lines to run. If you see them, copy
  and run them. On most modern Macs they are these two (paste both):

  ```bash
  echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
  eval "$(/opt/homebrew/bin/brew shellenv)"
  ```

Now install the tools wpsite needs (paste the whole line):

```bash
brew install yq imagemagick ffmpeg
```

---

## Step 3 — Install Docker Desktop

wpsite runs the website copies inside **Docker**. Install it:

```bash
brew install --cask docker
```

Then **open Docker once so it can finish setting up**:

1. Open **Finder → Applications → Docker** (double-click).
2. Accept the prompts. Wait until the little **whale icon** appears in the menu bar at the
   top of the screen and stops animating. Leave Docker running.

---

## Step 4 — Copy the wpsite program from Google Drive

1. In **Finder**, go to **Google Drive → Shared drives → 01_Projekte → 01_Global → wpsite**.
2. You'll see a folder named **`wpsite`** (the program) — this is the one to copy.
3. **Copy it to your Mac** (don't run it from inside Google Drive): click it once, press
   **⌘C**, then go to your **Applications** folder (or your home folder) and press **⌘V**.

> Why copy it out? Programs run from inside Google Drive can behave oddly because Drive is
> constantly syncing. A local copy is reliable.

---

## Step 5 — Install the `wpsite` command

1. Back in **Terminal**, type `cd ` (the letters c, d, and a **space**) — but don't press
   Return yet:

   ```bash
   cd 
   ```

2. Now **drag the copied `wpsite` folder** from Finder directly into the Terminal window.
   It fills in the folder's location for you. Press **Return**.

3. Run the installer (paste it):

   ```bash
   ./install.sh
   ```

   It may ask for your Mac password. When it finishes it prints a ✓.

4. Check it worked (paste):

   ```bash
   wpsite doctor
   ```

   You should see a list of green ✓ checks. (A warning about the team config is fine — the
   next step fixes it.)

---

## Step 6 — Connect to the team

This is the important one. Paste:

```bash
wpsite setup
```

It asks a few questions. Here's exactly what to do for each:

1. **"Local data dir (base_dir)"** → just press **Return** (the default is fine).

2. **"Shared team config path…"** → In Finder, go to **Google Drive → Shared drives →
   01_Projekte → 01_Global → wpsite** and find the file **`wpsite.team.yml`**. **Drag that
   file into the Terminal window**, then press **Return**.

3. **"Cloud backup root (cloud_base)…"** → In Finder, go to **Google Drive → Shared drives →
   01_Projekte** and find the **`LIVE_WEB`** folder. **Drag that folder into the Terminal
   window**, then press **Return**.

4. **Creating your SSH key** (only the first time): it makes a secure "key" so you can reach
   the client servers. When it asks for a **passphrase**, the simplest choice is to press
   **Return twice** (no passphrase). Then it continues.

5. **Connecting to each client** → For every client it may ask:
   - *"Are you sure you want to continue connecting?"* → type **`yes`** and press Return.
   - A **password for that server** → enter it if you have it (ask Beren if unsure). If you
     don't have a particular server's password, that client is skipped — you can add it
     later; the rest still work.

When it finishes it lists which clients are ready. 🎉

Check everything:

```bash
wpsite doctor
wpsite list
```

`wpsite list` should show the shared client list. You can now make a local copy of any
client, e.g.:

```bash
wpsite backup ehmann     # fetch a fresh snapshot
wpsite build ehmann      # build the local copy → opens at http://ehmann.test
```

---

## Step 7 — Install the desktop app (optional, but nicer)

If you'd rather click than type, there's a **wpsite** desktop app.

1. In **Finder**, go to **Google Drive → Shared drives → 01_Projekte → 01_Global → wpsite →
   app**, and find **`wpsite.app`**.
2. **Drag `wpsite.app` into your Applications folder.**
3. The first time you open it: **right-click** the app → **Open** → **Open** again in the
   dialog. (macOS asks this once for apps not from the App Store; after that you can open it
   normally.)

The app uses everything you set up above, so **Steps 1–6 must be done first** — the app
won't work on its own.

---

## Using wpsite day to day

- Easiest: in **Claude Code**, type **`/wpsite`** and describe what you want in plain German
  (e.g. *"Sicherung für Ehmann erstellen und lokale Kopie bauen"*). It runs the right commands.
- Or use the desktop app.
- Or type commands yourself — `wpsite` on its own lists them all.

---

## If something goes wrong

- **"command not found: wpsite"** → Close Terminal, open it again, and retry. If it still
  fails, redo Step 5.
- **"team config unreachable" / no clients listed** → Google Drive isn't fully synced. Open
  Finder, click Google Drive, make sure **01_Projekte** is there, wait a minute, try again.
- **Docker / build errors** → Make sure Docker Desktop is running (the whale icon is in the
  menu bar). Open it from Applications if not.
- **A client was skipped during setup** → You didn't have that server's password. Get it,
  then run `wpsite setup --keys-only` to finish, or ask Beren.
- **Still stuck?** Send Beren a screenshot of the Terminal — the error text tells him exactly
  what's wrong.

---

## For the person who maintains this (admin notes)

To make the "copy from Google Drive" steps above work, two things must be in the shared drive
at **`01_Projekte/01_Global/wpsite/`** (next to `wpsite.team.yml`):

1. **A copy of the `wpsite` program folder** (this repository). Refresh it there whenever you
   ship changes so colleagues copy the current version.
2. **The built desktop app** at **`…/wpsite/app/wpsite.app`** (build it once with the steps in
   [`GUI-Install.md`](GUI-Install.md), then drop the `.app` there). Rebuild + replace on updates.

Notes:
- `base_dir`, `cloud_base` and `team_config` are **per-person** (each colleague's Google Drive
  path contains their own account), which is why Step 6 uses drag-and-drop to fill them in
  rather than a fixed path.
- SSH keys are **per-person**: sharing the config does not share server access. Each colleague
  runs `wpsite setup`, which creates their key and installs it on each client (that's the
  password prompts). Authorize/revoke a person by adding/removing their key on the servers.
- Retention is fixed at **5 backups** per client; nobody needs to configure it.
