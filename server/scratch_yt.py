import yt_dlp

ydl_opts = {
    'quiet': True,
    'extract_flat': True,
}
with yt_dlp.YoutubeDL(ydl_opts) as ydl:
    info = ydl.extract_info("ytsearch10:Top Hits 2024", download=False)
    if 'entries' in info:
        for e in info['entries']:
            print(f"Title: {e.get('title')} - ID: {e.get('id')}")
    else:
        print("No entries")
