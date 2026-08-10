(function () {
  var articles = Array.prototype.slice.call(document.querySelectorAll(".help-article"));
  var links = Array.prototype.slice.call(document.querySelectorAll(".help-topic-link"));
  var searches = Array.prototype.slice.call(document.querySelectorAll("[data-help-search]"));
  var searchStatuses = Array.prototype.slice.call(document.querySelectorAll("[data-help-search-status]"));
  var topicSelect = document.getElementById("help-topic-select");
  var searchDataElement = document.getElementById("help-search-data");
  var searchData = searchDataElement ? JSON.parse(searchDataElement.textContent) : [];
  var topicIDs = articles.map(function (article) { return article.dataset.topic; });

  document.documentElement.classList.add("help-js");

  function topicFromHash() {
    var hash = decodeURIComponent(window.location.hash.replace(/^#/, ""));
    if (topicIDs.indexOf(hash) !== -1) return hash;
    var containingArticle = hash ? document.getElementById(hash) : null;
    return containingArticle && containingArticle.closest(".help-article")
      ? containingArticle.closest(".help-article").dataset.topic
      : topicIDs[0];
  }

  function showTopic(topicID, preserveSection) {
    if (topicIDs.indexOf(topicID) === -1) topicID = topicIDs[0];
    articles.forEach(function (article) {
      article.classList.toggle("is-active", article.dataset.topic === topicID);
    });
    links.forEach(function (link) {
      var active = link.dataset.topic === topicID;
      link.classList.toggle("is-active", active);
      if (active) link.setAttribute("aria-current", "page");
      else link.removeAttribute("aria-current");
    });
    if (topicSelect) topicSelect.value = topicID;
    if (!preserveSection && window.location.hash !== "#" + topicID) {
      history.replaceState(null, "", "#" + topicID);
    }
  }

  function runSearch() {
    var query = searches.length ? searches[0].value.trim().toLocaleLowerCase() : "";
    var matches = searchData.filter(function (topic) {
      return !query || topic.text.toLocaleLowerCase().indexOf(query) !== -1;
    });
    var matchingIDs = matches.map(function (topic) { return topic.id; });
    links.forEach(function (link) {
      link.hidden = matchingIDs.indexOf(link.dataset.topic) === -1;
    });
    var status = !query ? "" : (matches.length === 1 ? "1 matching topic" : matches.length + " matching topics");
    searchStatuses.forEach(function (element) { element.textContent = status; });
    if (query && matches.length && matchingIDs.indexOf(topicFromHash()) === -1) {
      showTopic(matches[0].id, false);
    }
  }

  links.forEach(function (link) {
    link.addEventListener("click", function () {
      searches.forEach(function (element) { element.value = ""; });
      runSearch();
    });
  });
  searches.forEach(function (element) {
    element.addEventListener("input", function () {
      var value = element.value;
      searches.forEach(function (other) { if (other !== element) other.value = value; });
      runSearch();
    });
  });
  if (topicSelect) {
    topicSelect.addEventListener("change", function () {
      window.location.hash = topicSelect.value;
    });
  }
  window.addEventListener("hashchange", function () {
    showTopic(topicFromHash(), true);
    var target = document.getElementById(decodeURIComponent(window.location.hash.replace(/^#/, "")));
    if (target && !target.classList.contains("help-article")) target.scrollIntoView();
    else window.scrollTo(0, 0);
  });

  showTopic(topicFromHash(), true);
  runSearch();
})();
