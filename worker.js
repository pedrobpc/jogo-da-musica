const JSON_HEADERS = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "public, max-age=300"
};

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: JSON_HEADERS
  });
}

function isSpotifyTrackUrl(value) {
  try {
    const u = new URL(value);
    const host = u.hostname.toLowerCase().replace(/^www\./, "");
    if (host === "spotify.link") return true;
    if (host !== "open.spotify.com") return false;
    return /^\/(?:intl-[^/]+\/)?track\/[A-Za-z0-9]+\/?$/i.test(u.pathname);
  } catch {
    return false;
  }
}

async function spotifyOEmbed(target) {
  const endpoint =
    "https://open.spotify.com/oembed?url=" +
    encodeURIComponent(target);

  const r = await fetch(endpoint, {
    headers: {
      "accept": "application/json",
      "user-agent": "the-ultimate-jogo-da-musica/7.2"
    }
  });

  if (!r.ok) {
    return json(
      { error: `O Spotify recusou a consulta (HTTP ${r.status}).` },
      502
    );
  }

  const data = await r.json();

  const title = typeof data.title === "string" ? data.title.trim() : "";
  const artist =
    typeof data.author_name === "string" ? data.author_name.trim() : "";
  const albumArt =
    typeof data.thumbnail_url === "string" ? data.thumbnail_url : "";

  if (!title) {
    return json(
      { error: "O Spotify não retornou o título dessa faixa." },
      422
    );
  }

  if (!artist) {
    return json(
      {
        error:
          "O Spotify retornou a faixa, mas não informou o artista no oEmbed."
      },
      422
    );
  }

  return json({
    title,
    artist,
    album_art_url: albumArt,
    spotify_url: target
  });
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // Our API route. It runs before static assets.
    if (url.pathname === "/api/spotify") {
      if (request.method !== "GET") {
        return json({ error: "Método não permitido." }, 405);
      }

      const target = url.searchParams.get("url");
      if (!target) {
        return json({ error: "Informe uma URL do Spotify." }, 400);
      }

      if (!isSpotifyTrackUrl(target)) {
        return json(
          {
            error:
              "Use uma URL de uma faixa (track) do Spotify, como https://open.spotify.com/track/..."
          },
          422
        );
      }

      try {
        return await spotifyOEmbed(target);
      } catch (error) {
        return json(
          {
            error:
              `Não foi possível consultar o Spotify: ${
                error?.message || "erro desconhecido"
              }.`
          },
          502
        );
      }
    }

    // Every other request is handled by the static-assets binding.
    return env.ASSETS.fetch(request);
  }
};
