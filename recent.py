import os

import spotipy
from dotenv import load_dotenv
from spotipy.oauth2 import SpotifyOAuth

load_dotenv()

sp = spotipy.Spotify(auth_manager=SpotifyOAuth(
    client_id=os.environ["SPOTIFY_CLIENT_ID"],
    client_secret=os.environ["SPOTIFY_CLIENT_SECRET"],
    redirect_uri="http://127.0.0.1:8000/callback",
    scope="user-read-recently-played",
    cache_path=".spotify-token",
))

results = sp.current_user_recently_played(limit=50)

for i, item in enumerate(results["items"], 1):
    track = item["track"]
    artists = ", ".join(a["name"] for a in track["artists"])
    played = item["played_at"][:16].replace("T", " ")  # UTC time
    print(f"{i:2}. {played} UTC  {track['name']} - {artists}")