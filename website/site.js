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

    return { owner: "chrisgherbert", repo: "inout" };
  }

  function setDownloadLink(url, label) {
    var primary = document.getElementById("download-btn");
    var secondary = document.getElementById("download-btn-secondary");
    var releasesLink = document.getElementById("releases-link");
    var repoLink = document.getElementById("repo-link");
    if (primary) {
      primary.href = url;
      if (label) primary.textContent = label;
    }
    if (secondary) {
      secondary.href = url;
      if (label) secondary.textContent = label;
    }
    var repo = deriveRepo();
    var repoUrl = "https://github.com/" + repo.owner + "/" + repo.repo;
    if (releasesLink) releasesLink.href = repoUrl + "/releases";
    if (repoLink) repoLink.href = repoUrl;

  }

  function setMetaText(text) {
    var meta = document.getElementById("release-meta");
    if (meta) meta.textContent = text;
  }

  function findInstallerAsset(assets) {
    if (!Array.isArray(assets)) return null;

    var dmgAsset = assets.find(function (asset) {
      return /^(In[-_ ]?Out.*\.dmg)$/i.test(asset.name) && !/\.sha256$/i.test(asset.name);
    });
    if (dmgAsset && dmgAsset.browser_download_url) return dmgAsset;

    var zipAsset = assets.find(function (asset) {
      return /^(In[-_ ]?Out.*\.zip)$/i.test(asset.name) && !/\.sha256$/i.test(asset.name);
    });
    if (zipAsset && zipAsset.browser_download_url) return zipAsset;

    return null;
  }

  async function hydrateLatestDownload() {
    var repo = deriveRepo();
    var releasesUrl = "https://github.com/" + repo.owner + "/" + repo.repo + "/releases";
    var fallback = releasesUrl + "/latest";
    setDownloadLink(fallback, "Download for Mac");

    try {
      var api = "https://api.github.com/repos/" + repo.owner + "/" + repo.repo + "/releases/latest";
      var response = await fetch(api, { headers: { Accept: "application/vnd.github+json" } });
      if (!response.ok) throw new Error("HTTP " + response.status);

      var release = await response.json();
      var assets = Array.isArray(release.assets) ? release.assets : [];
      var installerAsset = findInstallerAsset(assets);

      if (installerAsset && installerAsset.browser_download_url) {
        setDownloadLink(installerAsset.browser_download_url, "Download for Mac");
        setMetaText(release.tag_name + " · " + (/\.dmg$/i.test(installerAsset.name) ? "DMG installer" : "ZIP download"));
      } else {
        setDownloadLink(fallback, "View Releases");
        setMetaText("Choose an installer on GitHub.");
      }
    } catch (err) {
      setDownloadLink(fallback, "View Releases");
      setMetaText("Download the latest installer from GitHub.");
      console.warn("In/Out release lookup failed:", err);
    }
  }

  hydrateLatestDownload();
})();
