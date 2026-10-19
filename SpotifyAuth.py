#!/usr/bin/env python3
"""
Gets a Spotify REFRESH TOKEN for FMenu. Run it ONCE on your own computer (Python 3.8+, nothing to install).

Why this exists: Spotify only gives out long-lived access through a browser login. Roblox cannot open a browser,
so this script does the login for you and prints a "refresh token" that FMenu can use forever after.

Steps
  1. Go to https://developer.spotify.com/dashboard and press "Create app".
       Redirect URI : http://127.0.0.1:8888/callback      (exactly this, then press Add and Save)
       APIs used    : tick "Web API"
  2. Open the app's Settings and copy the Client ID and (View client secret) the Client secret.
  3. Run this file:
       python spotify_auth.py            (it asks for the two values)
       python spotify_auth.py <client_id> <client_secret>
  4. A browser tab opens. Log in to Spotify and press Agree.
  5. The refresh token is printed in this window. Paste Client ID, Client secret and the token into
     FMenu: Config > "Spotify on pill" > right-click.

If the browser does not open or the page says it cannot connect, the script waits 2 minutes and then lets you
paste the address of that page instead (it contains ?code=...). That works without any local server.
"""
import base64
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer

REDIRECT = "http://127.0.0.1:8888/callback"
SCOPES = "user-read-playback-state user-modify-playback-state"


def wait_for_code(auth_url):
    """Local server on 127.0.0.1:8888 catches the redirect. Returns the code, or None when that did not work."""
    result = {}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if "code" in query or "error" in query:
                result["code"] = query.get("code", [None])[0]
                result["error"] = query.get("error", [None])[0]
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"Done. You can close this tab and go back to the terminal.")

        def log_message(self, *args):
            pass

    try:
        server = HTTPServer(("127.0.0.1", 8888), Handler)
    except OSError as e:
        print(f"Could not start the local listener on port 8888 ({e}). Using the paste method instead.")
        return None

    server.timeout = 1
    print("1) Your browser should open now. If it does not, open this address yourself:\n")
    print(auth_url + "\n")
    print("2) Log in to Spotify and press Agree. Waiting up to 2 minutes...")
    webbrowser.open(auth_url)

    deadline = time.time() + 120
    while time.time() < deadline and "code" not in result and "error" not in result:
        server.handle_request()
    server.server_close()

    if result.get("error"):
        print("Spotify answered with an error:", result["error"])
        return None
    return result.get("code")


def ask_for_code():
    print("\nPaste the full address from your browser's address bar after pressing Agree.")
    print("(It starts with http://127.0.0.1:8888/callback?code=... The page itself may say it cannot connect, that is fine.)")
    text = input("Address: ").strip()
    query = urllib.parse.parse_qs(urllib.parse.urlparse(text).query)
    code = query.get("code", [None])[0]
    if not code and text and "=" not in text and "/" not in text:
        code = text  # they pasted just the code
    return code


def main():
    interactive = len(sys.argv) != 3
    if interactive:
        print(__doc__)
        client_id = input("Client ID: ").strip()
        client_secret = input("Client secret: ").strip()
    else:
        client_id, client_secret = sys.argv[1], sys.argv[2]
    if not client_id or not client_secret:
        print("Client ID and Client secret are both needed.")
        return 1

    auth_url = "https://accounts.spotify.com/authorize?" + urllib.parse.urlencode(
        {"client_id": client_id, "response_type": "code", "redirect_uri": REDIRECT, "scope": SCOPES}
    )
    code = wait_for_code(auth_url)
    if not code:
        print("\nNo code received automatically.")
        print("If your browser showed 'INVALID_CLIENT: Invalid redirect URI', the Redirect URI in your Spotify app")
        print(f"must be exactly:  {REDIRECT}")
        code = ask_for_code()
    if not code:
        print("No code, nothing to do. Run the script again.")
        return 1

    body = urllib.parse.urlencode(
        {"grant_type": "authorization_code", "code": code, "redirect_uri": REDIRECT}
    ).encode()
    auth = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
    req = urllib.request.Request(
        "https://accounts.spotify.com/api/token",
        data=body,
        headers={"Authorization": "Basic " + auth, "Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as res:
            data = json.load(res)
    except urllib.error.HTTPError as e:
        print("Spotify refused the code:", e.read().decode())
        print("Most common reasons: wrong Client secret, or the code was already used (run the script again).")
        return 1
    except urllib.error.URLError as e:
        print("Could not reach Spotify:", e.reason)
        return 1

    print("\n" + "=" * 60)
    print("Refresh token (paste this into FMenu):\n")
    print(data["refresh_token"])
    print("=" * 60)
    print("\nAlso paste your Client ID and Client secret. Keep all three private.")
    return 0


if __name__ == "__main__":
    code = main()
    if len(sys.argv) != 3:
        input("\nPress Enter to close...")  # keeps the window open when started by double click
    sys.exit(code)
