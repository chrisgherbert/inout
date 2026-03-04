(function () {
  function deriveRepo() {
    var host = window.location.hostname;
    var pathParts = window.location.pathname.split("/").filter(Boolean);

    if (host.endsWith(".github.io")) {
      var owner = host.split(".")[0];
      var repo = pathParts.length > 0 ? pathParts[0] : "";
      if (repo) return { owner: owner, repo: repo };
    }

    if (window.IN_AND_OUT_REPO && window.IN_AND_OUT_REPO.owner && window.IN_AND_OUT_REPO.repo) {
      return {
        owner: window.IN_AND_OUT_REPO.owner,
        repo: window.IN_AND_OUT_REPO.repo
      };
    }

    return null;
  }

  function setDownloadLink(url, label) {
    var primary = document.getElementById("download-btn");
    var secondary = document.getElementById("download-btn-secondary");
    var releasesLink = document.getElementById("releases-link");
    var repoLink = document.getElementById("repo-link");
    var meta = document.getElementById("release-meta");

    if (primary) {
      primary.href = url;
      if (label) primary.textContent = label;
    }
    if (secondary) secondary.href = url;
    if (releasesLink) releasesLink.href = url.includes("/download/") ? url.split("/releases/")[0] + "/releases" : url;
    if (repoLink && releasesLink && releasesLink.href) repoLink.href = releasesLink.href.replace(/\/releases$/, "");
    if (meta) meta.textContent = "Latest release ready";
  }

  function setMetaText(text) {
    var meta = document.getElementById("release-meta");
    if (meta) meta.textContent = text;
  }

  async function hydrateLatestDownload() {
    var repo = deriveRepo();
    if (!repo) {
      setMetaText("Set IN_AND_OUT_REPO in site.js for non-GitHub Pages hosting.");
      return;
    }

    var releasesUrl = "https://github.com/" + repo.owner + "/" + repo.repo + "/releases";
    var fallback = releasesUrl + "/latest";
    setDownloadLink(fallback, "Download for macOS");

    try {
      var api = "https://api.github.com/repos/" + repo.owner + "/" + repo.repo + "/releases/latest";
      var response = await fetch(api, { headers: { Accept: "application/vnd.github+json" } });
      if (!response.ok) throw new Error("HTTP " + response.status);

      var release = await response.json();
      var assets = Array.isArray(release.assets) ? release.assets : [];
      var zipAsset = assets.find(function (asset) {
        return /^(In[-_ ]?Out.*\.zip)$/i.test(asset.name) || /\.zip$/i.test(asset.name);
      });

      if (zipAsset && zipAsset.browser_download_url) {
        setDownloadLink(zipAsset.browser_download_url, "Download for macOS");
        setMetaText("Latest: " + release.tag_name);
      } else {
        setDownloadLink(fallback, "View Releases");
        setMetaText("Latest release found, but no zip asset matched.");
      }
    } catch (err) {
      setDownloadLink(fallback, "View Releases");
      setMetaText("Could not resolve latest asset automatically. Using Releases page.");
      console.warn("In/Out release lookup failed:", err);
    }
  }

  hydrateLatestDownload();
})();
