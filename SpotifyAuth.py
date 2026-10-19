#!/usr/bin/env python3
"""
Gets a Spotify REFRESH TOKEN for FMenu. Run it once on your own computer (standard library only, Python 3.8+).

  1. https://developer.spotify.com/dashboard  ->  Create app
       Redirect URI:  http://127.0.0.1:8888/callback
       (tick "Web API")
  2. Copy the app's Client ID and Client secret.
  3. python spotify_auth.py <client_id> <client_secret>
  4. Your browser opens, log in and press Agree. The refresh token is printed here.
  5. In FMenu: Config > "Spotify on pill" > right-click > paste Client ID, Client secret and Refresh token.

The refresh token does not expire until you revoke the app, so this is a one-time step.
Keep it private: anyone with the client secret + refresh token can control your Spotify.
"""
import base64
import json
import sys
import threading
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer

REDIRECT = "http://127.0.0.1:8888/callback"
SCOPES = "user-read-playback-state user-modify-playback-state"


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    client_id, client_secret = sys.argv[1], sys.argv[2]

    result = {}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            result["code"] = query.get("code", [None])[0]
            result["error"] = query.get("error", [None])[0]
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"Done, you can close this tab and go back to the terminal.")
            threading.Thread(target=self.server.shutdown, daemon=True).start()

        def log_message(self, *args):
            pass

    server = HTTPServer(("127.0.0.1", 8888), Handler)
    url = "https://accounts.spotify.com/authorize?" + urllib.parse.urlencode(
        {
            "client_id": client_id,
            "response_type": "code",
            "redirect_uri": REDIRECT,
            "scope": SCOPES,
        }
    )
    print("Opening your browser. If nothing opens, go to:\n" + url + "\n")
    webbrowser.open(url)
    server.serve_forever()

    if not result.get("code"):
        print("Authorization failed:", result.get("error") or "no code received")
        sys.exit(1)

    body = urllib.parse.urlencode(
        {"grant_type": "authorization_code", "code": result["code"], "redirect_uri": REDIRECT}
    ).encode()
    auth = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
    req = urllib.request.Request(
        "https://accounts.spotify.com/api/token",
        data=body,
        headers={"Authorization": "Basic " + auth, "Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with urllib.request.urlopen(req) as res:
            data = json.load(res)
    except urllib.error.HTTPError as e:
        print("Token request failed:", e.read().decode())
        sys.exit(1)

    print("\nRefresh token (paste this into FMenu):\n")
    print(data["refresh_token"])


if __name__ == "__main__":
    main()
