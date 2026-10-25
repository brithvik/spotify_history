"""Save your recent Spotify plays to PostgreSQL, skipping ones already saved.

Runs once and exits. Later, a Kubernetes CronJob will run it every few minutes.
"""
import os
from datetime import datetime

import psycopg
import spotipy
from dotenv import load_dotenv
from spotipy.oauth2 import SpotifyOAuth

load_dotenv()

CREATE_TRACKS = """
CREATE TABLE IF NOT EXISTS tracks (
    track_id    TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    artists     TEXT NOT NULL,
    album       TEXT,
    duration_ms INTEGER
)
"""

CREATE_PLAYS = """
CREATE TABLE IF NOT EXISTS plays (
    user_id   TEXT NOT NULL,
    played_at TIMESTAMPTZ NOT NULL,
    track_id  TEXT NOT NULL REFERENCES tracks(track_id),
    source    TEXT NOT NULL DEFAULT 'api',
    PRIMARY KEY (user_id, played_at, track_id)
)
"""


def main():
    sp = spotipy.Spotify(auth_manager=SpotifyOAuth(
        client_id=os.environ["SPOTIFY_CLIENT_ID"],
        client_secret=os.environ["SPOTIFY_CLIENT_SECRET"],
        redirect_uri="http://127.0.0.1:8000/callback",
        scope="user-read-recently-played",
        cache_path=".spotify-token",
    ))

    user_id = sp.current_user()["id"]
    items = sp.current_user_recently_played(limit=50)["items"]

    new_plays = 0
    skipped = 0
    with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
        conn.execute(CREATE_TRACKS)
        conn.execute(CREATE_PLAYS)

        for item in items:
            track = item["track"]
            if not track or not track.get("id"):  # local files have no Spotify ID
                if not track or not track.get("id"):  # local files have no Spotify ID
                    skipped += 1
                continue

            conn.execute(
                """INSERT INTO tracks (track_id, name, artists, album, duration_ms)
                   VALUES (%s, %s, %s, %s, %s)
                   ON CONFLICT (track_id) DO NOTHING""",
                (
                    track["id"],
                    track["name"],
                    ", ".join(a["name"] for a in track["artists"]),
                    track["album"]["name"],
                    track["duration_ms"],
                ),
            )

            played_at = datetime.fromisoformat(item["played_at"].replace("Z", "+00:00"))
            cur = conn.execute(
                """INSERT INTO plays (user_id, played_at, track_id)
                   VALUES (%s, %s, %s)
                   ON CONFLICT DO NOTHING""",
                (user_id, played_at, track["id"]),
            )
            new_plays += cur.rowcount

        total = conn.execute(
            "SELECT count(*) FROM plays WHERE user_id = %s", (user_id,)
        ).fetchone()[0]

    already = len(items) - new_plays - skipped
    print(f"Saved {new_plays} new, {already} already saved, {skipped} skipped. "
          f"Total stored: {total}")


if __name__ == "__main__":
    main()
