export async function onRequestGet(context) {
  const requestUrl = new URL(context.request.url);
  const target = requestUrl.searchParams.get("url");

  const json = (body, status = 200) =>
    Response.json(body, {
      status,
      headers: {
        "Cache-Control": "public, max-age=86400"
      }
    });

  if (!target) {
    return json(
      { error: "Informe uma URL do Spotify." },
      400
    );
  }

  let parsed;

  try {
    parsed = new URL(target);
  } catch {
    return json(
      { error: "URL do Spotify inválida." },
      400
    );
  }

  const host = parsed.hostname
    .toLowerCase()
    .replace(/^www\./, "");

  if (
    host !== "open.spotify.com" &&
    host !== "spotify.link"
  ) {
    return json(
      { error: "Use uma URL pública do Spotify." },
      400
    );
  }

  const path = parsed.pathname.replace(/\/+$/, "");

  const isTrack =
    /^\/(?:intl-[^/]+\/)?track\/[A-Za-z0-9]+$/i.test(path) ||
    host === "spotify.link";

  if (!isTrack) {
    return json(
      {
        error:
          "Use o link de uma faixa (track) do Spotify, não de álbum ou playlist."
      },
      422
    );
  }

  try {
    const oembedUrl =
      "https://open.spotify.com/oembed?url=" +
      encodeURIComponent(target);

    const response = await fetch(oembedUrl, {
      headers: {
        Accept: "application/json",
        "User-Agent":
          "the-ultimate-jogo-da-musica/7.2"
      }
    });

    if (!response.ok) {
      return json(
        {
          error:
            `O Spotify recusou a consulta (HTTP ${response.status}).`
        },
        502
      );
    }

    const data = await response.json();

    const title =
      typeof data.title === "string"
        ? data.title.trim()
        : "";

    const artist =
      typeof data.author_name === "string"
        ? data.author_name.trim()
        : "";

    const albumArt =
      typeof data.thumbnail_url === "string"
        ? data.thumbnail_url
        : "";

    if (!title || !artist) {
      return json(
        {
          error:
            "O Spotify não retornou título e artista para esta faixa."
        },
        422
      );
    }

    return json({
      title,
      artist,
      album_art_url: albumArt
    });
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
