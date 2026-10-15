// www.appea.rs → https://appea.rs, keeping the path and query string.
export default {
  fetch(request) {
    const url = new URL(request.url);
    url.protocol = "https:";
    url.hostname = "appea.rs";
    url.port = "";
    return Response.redirect(url.href, 301);
  },
};
