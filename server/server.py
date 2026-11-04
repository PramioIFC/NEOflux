from flask import Flask, Response, request, jsonify, stream_with_context
from flask_cors import CORS
import yt_dlp
import requests as http_requests
import os
import sys
from pyngrok import ngrok
from cachetools import cached, TTLCache

app = Flask(__name__)
CORS(app)

# Cria um cache na memória para guardar os URLs extraídos.
# Guarda até 1000 músicas. Expira a cada 4 horas (14400 segundos) pois os links do YouTube expiram.
url_cache = TTLCache(maxsize=1000, ttl=14400)

@cached(url_cache)
def extract_youtube_audio_info(video_id, quality="normal"):
    video_url = f"https://www.youtube.com/watch?v={video_id}"
    
    format_str = 'bestaudio/best'
    if quality == 'lossless':
        format_str = 'bestaudio[acodec=flac]/bestaudio[acodec=opus]/bestaudio/best'
    elif quality == 'high':
        format_str = 'bestaudio[abr>128]/bestaudio/best'
    elif quality == 'low':
        format_str = 'worstaudio/worst'

    ydl_opts = {
        'format': format_str,
        'quiet': True,
        'no_warnings': True,
        'force_generic_extractor': False,
        # ANDROID_VR audio-only URLs are currently truncated/forbidden after
        # the first megabyte for some videos. The regular Android client
        # provides a complete MP4 stream that ExoPlayer can play reliably.
        'extractor_args': {'youtube': {'player_client': ['android']}},
    }
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(video_url, download=False)
        return {
            "title": info.get('title'),
            "url": info['url'],
            "http_headers": info.get('http_headers') or {},
        }

@app.route('/get_audio', methods=['GET'])
def get_audio():
    video_id = request.args.get('id')
    quality = request.args.get('quality', 'normal')
    if not video_id:
        return jsonify({"error": "No ID provided"}), 400

    try:
        # Tenta pegar do cache primeiro, ou busca no yt-dlp
        data = extract_youtube_audio_info(video_id, quality)
        return jsonify({"title": data["title"], "url": data["url"]})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/stream_audio', methods=['GET'])
def stream_audio():
    video_id = request.args.get('id')
    quality = request.args.get('quality', 'normal')
    if not video_id:
        return jsonify({"error": "No ID provided"}), 400

    try:
        data = extract_youtube_audio_info(video_id, quality)
        base_headers = dict(data.get('http_headers') or {})

        # Some Googlevideo URLs reject large or open-ended requests with HTTP
        # 403. Fetch small accepted ranges and join them into one continuous
        # response for ExoPlayer.
        chunk_size = 128 * 1024
        client_range = request.headers.get('Range')
        range_start = 0
        requested_end = None
        if client_range and client_range.startswith('bytes='):
            range_spec = client_range[6:].split(',', 1)[0]
            start_text, end_text = range_spec.split('-', 1)
            if start_text:
                range_start = int(start_text)
            if end_text:
                requested_end = int(end_text)

        def fetch_chunk(start, end):
            headers = dict(base_headers)
            headers['Range'] = f'bytes={start}-{end}'
            response = http_requests.get(
                data['url'], headers=headers, stream=True, timeout=30
            )
            response.raise_for_status()
            return response

        first_end = range_start + chunk_size - 1
        if requested_end is not None:
            first_end = min(first_end, requested_end)
        first_response = fetch_chunk(range_start, first_end)

        content_range = first_response.headers.get('Content-Range', '')
        total_text = content_range.rsplit('/', 1)[-1]
        total_length = int(total_text)
        target_end = requested_end if requested_end is not None else total_length - 1
        final_end = min(target_end, total_length - 1)

        response_headers = {
            'Accept-Ranges': 'bytes',
            'Content-Length': str(final_end - range_start + 1),
            'Content-Type': first_response.headers.get(
                'Content-Type', 'audio/webm'
            ),
        }
        status_code = 200
        if client_range:
            status_code = 206
            response_headers['Content-Range'] = (
                f'bytes {range_start}-{final_end}/{total_length}'
            )

        def generate():
            current_start = range_start
            upstream = first_response
            try:
                while current_start <= final_end:
                    try:
                        for chunk in upstream.iter_content(chunk_size=64 * 1024):
                            if chunk:
                                yield chunk
                    finally:
                        upstream.close()

                    current_start += chunk_size
                    if current_start <= final_end:
                        upstream = fetch_chunk(
                            current_start,
                            min(current_start + chunk_size - 1, final_end),
                        )
            finally:
                upstream.close()

        return Response(
            stream_with_context(generate()),
            status=status_code,
            headers=response_headers,
        )
    except Exception as e:
        return jsonify({"error": str(e)}), 502

@app.route('/search', methods=['GET'])
def search():
    query = request.args.get('q')
    if not query:
        return jsonify({"error": "No query provided"}), 400
    
    try:
        ydl_opts = {
            'quiet': True,
            'extract_flat': True,
        }
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(f"ytsearch1:{query} audio", download=False)
            if 'entries' in info and len(info['entries']) > 0:
                video = info['entries'][0]
                return jsonify({
                    "video_id": video.get('id'),
                    "title": video.get('title')
                })
            else:
                return jsonify({"error": "No results found"}), 404
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/trending', methods=['GET'])
def trending():
    query = request.args.get('q', 'Top Hits Music 2024')
    try:
        ydl_opts = {
            'quiet': True,
            'extract_flat': True,
        }
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(f"ytsearch15:{query}", download=False)
            results = []
            if 'entries' in info:
                for video in info['entries']:
                    if video.get('id'):
                        results.append({
                            "video_id": video.get('id'),
                            "title": video.get('title'),
                            "channel": video.get('uploader')
                        })
            return jsonify(results)
    except Exception as e:
        return jsonify({"error": str(e)}), 500

PORT = 9000

# Pega o Token do Ngrok das variáveis de ambiente do Docker
NGROK_TOKEN = os.environ.get("NGROK_AUTHTOKEN", "").strip()

# Verifica se não está rodando no reloader do Flask para evitar abrir dois túneis
if NGROK_TOKEN and os.environ.get("WERKZEUG_RUN_MAIN") != "true":
    print("\n[Flux] Configurando túnel Ngrok automático...")
    ngrok.set_auth_token(NGROK_TOKEN)
    
    # Pega o domínio das variáveis de ambiente (se existir)
    # Aceita tanto "dominio.ngrok-free.app" quanto uma URL copiada do painel.
    NGROK_DOMAIN = os.environ.get("NGROK_DOMAIN", "").strip()
    NGROK_DOMAIN = NGROK_DOMAIN.removeprefix("https://").removeprefix("http://").rstrip("/")
    
    if NGROK_DOMAIN:
        print(f"[Flux] Usando domínio estático: {NGROK_DOMAIN}")
        # Abre o túnel usando o domínio fixo reservado
        public_url = ngrok.connect(PORT, domain=NGROK_DOMAIN)
    else:
        print("[Flux] Nenhum domínio informado. Gerando link aleatório...")
        # Abre o túnel padrão (gera link aleatório)
        public_url = ngrok.connect(PORT)
        
    print("\n" + "="*60)
    print(f"🚀 LINK PARA COLOCAR NO FLUX APP:\n👉 {public_url.public_url} 👈")
    print("="*60 + "\n")

if __name__ == '__main__':
    # Executa o servidor Flask
    app.run(host='0.0.0.0', port=PORT)
