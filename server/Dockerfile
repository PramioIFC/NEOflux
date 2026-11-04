# Deno is required by current yt-dlp releases to solve YouTube's JavaScript
# challenges. Copying the official binary keeps the runtime self-contained.
FROM denoland/deno:bin-2.9.5 AS deno

# Use a lightweight Python Linux base
FROM python:3.12-slim

COPY --from=deno /deno /usr/local/bin/deno

# Set the working directory inside the container
WORKDIR /app

# Copy the requirements file first (optimizes build caching)
COPY requirements.txt .

# Install dependencies inside the container's global space
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of your server code
COPY . .

# Expose the port your Flask app runs on
EXPOSE 9000

# Run the server using Gunicorn for better performance
CMD ["gunicorn", "--bind", "0.0.0.0:9000", "--workers", "2", "--threads", "4", "--preload", "server:app"]
