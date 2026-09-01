const json = (body, status = 200, extraHeaders = {}) =>
  Response.json(body, {
    status,
    headers: {
      "Cache-Control": "no-store",
      "Access-Control-Allow-Origin": "*",
      ...extraHeaders,
    },
  });

function decodeHtml(value) {
  return String(value || "")
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .trim();
}

function extractArtist(html) {
  if (!html) return "";

  const strategies = [
    // JSON-LD / structured data.
    /"byArtist"\s*:\s*\{[^{}]*?"name"\s*:\s*"([^"]+)"/i,
    /"artist"\s*:\s*\{[^{}]*?"name"\s*:\s*"([^"]+)"/i,

    // Artist link in the Spotify embed HTML.
    /href=["'](?:https?:\/\/open\.spotify\.com)?\/artist\/[A-Za-z0-9]+[^"']*["'][^>]*>\s*([^<]+?)\s*<\/a>/i,
    /href=["'][^"']*\/artist\/[A-Za-z0-9]+[^"']*["'][^>]*>\s*([^<]+?)\s*<\/a>/i,

    // Common metadata forms.
    /itemprop=["']byArtist["'][^>]*content=["']([^"']+)["']/i,
    /property=["']music:musician["'][^>]*content=["']([^"']+)["']/i,
  ];

  for (const pattern of strategies) {
    const match = html.match(pattern);
    if (match?.[1]) {
      const artist = decodeHtml(match[1]);
      if (artist && artist.length < 300) return artist;
    }
  }

  return "";
}

function validSpotifyTrackUrl(target) {
  try {
    const u = new URL(target);
    const host = u.hostname.toLowerCase().replace(/^www\./, "");
    if (host !== "open.spotify.com" && host !== "spotify.link") return false;
    if (host === "spotify.link") return true;
    return /^\/(?:intl-[^/]+\/)?track\/[A-Za-z0-9]+$/i.test(
      u.pathname.replace(/\/+$/, "")
    );
  } catch {
    return false;
  }
}

async function spotifyMetadata(target) {
  const oembedUrl =
    "https://open.spotify.com/oembed?url=" + encodeURIComponent(target);

  const oembedResponse = await fetch(oembedUrl, {
    headers: {
      Accept: "application/json",
      "User-Agent": "the-ultimate-jogo-da-musica/7.2",
    },
  });

  if (!oembedResponse.ok) {
    throw new Error(`Spotify oEmbed respondeu HTTP ${oembedResponse.status}.`);
  }

  const oembed = await oembedResponse.json();
  const title = typeof oembed.title === "string" ? oembed.title.trim() : "";
  const albumArt =
    typeof oembed.thumbnail_url === "string" ? oembed.thumbnail_url : "";
  const iframeUrl =
    typeof oembed.iframe_url === "string" ? oembed.iframe_url : "";

  if (!title || !iframeUrl) {
    throw new Error("O Spotify não retornou os metadados esperados para essa faixa.");
  }

  // oEmbed intentionally does not expose the artist as a separate field.
  // The public Spotify embed page does expose the artist link, so we use that
  // page only for the missing artist name. No Spotify credentials are needed.
  const embedResponse = await fetch(iframeUrl, {
    headers: {
      Accept: "text/html,application/xhtml+xml",
      "User-Agent": "the-ultimate-jogo-da-musica/7.2",
    },
  });

  let artist = "";
  if (embedResponse.ok) {
    artist = extractArtist(await embedResponse.text());
  }

  if (!artist) {
    throw new Error(
      "O Spotify retornou a música e a capa, mas não foi possível identificar o artista."
    );
  }

  return {
    title,
    artist,
    album_art_url: albumArt,
    spotify_url: target,
  };
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/api/spotify") {
      if (request.method === "OPTIONS") {
        return new Response(null, {
          status: 204,
          headers: {
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
          },
        });
      }

      if (request.method !== "GET") {
        return json({ error: "Método não permitido." }, 405);
      }

      const target = url.searchParams.get("url")?.trim();
      if (!target) return json({ error: "Informe uma URL do Spotify." }, 400);

      if (!validSpotifyTrackUrl(target)) {
        return json(
          {
            error:
              "Use uma URL de uma música individual (track) do Spotify.",
          },
          422
        );
      }

      try {
        return json(await spotifyMetadata(target), 200, {
          "Cache-Control": "public, max-age=86400",
        });
      } catch (error) {
        return json(
          {
            error:
              error?.message || "Não foi possível consultar o Spotify.",
          },
          502
        );
      }
    }

    // Every non-API request is handled by the static site assets.
    return env.ASSETS.fetch(request);
  },
};
