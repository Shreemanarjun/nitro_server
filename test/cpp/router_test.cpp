// Router unit tests: the trie is the "build now or pay later" item from the
// implementation plan, so it gets the deepest coverage in the C++ suite.
#include <gtest/gtest.h>

#include "engine/Router.h"

using namespace nitroserver;

namespace {

RouteEntry route(Method m, const std::string& pattern, int64_t timeout = -1) {
  return RouteEntry{m, "", pattern, timeout};
}

TEST(RouterTest, HeadFallsBackToGetThenAll) {
  Router r;
  ASSERT_TRUE(r.add({Method::Get, "", "/g", -1}));
  ASSERT_TRUE(r.add({Method::All, "", "/a", -1}));
  ASSERT_TRUE(r.add({Method::Get, "", "/both", -1}));
  ASSERT_TRUE(r.add({Method::Head, "", "/both", 7}));
  // A HEAD on a GET-only pattern matches the GET route.
  auto m = r.match(Method::Head, "", "/g");
  EXPECT_TRUE(m.matched);
  EXPECT_EQ(m.route->method, Method::Get);
  // An explicit HEAD route wins over the GET one.
  m = r.match(Method::Head, "", "/both");
  EXPECT_TRUE(m.matched);
  EXPECT_EQ(m.route->method, Method::Head);
  EXPECT_EQ(m.route->timeoutMs, 7);
  // The All fallback still applies when neither exists.
  EXPECT_TRUE(r.match(Method::Head, "", "/a").matched);
  // Other methods never fall back to GET.
  EXPECT_FALSE(r.match(Method::Post, "", "/g").matched);
}

TEST(RouterTest, RejectsMalformedPatterns) {
  Router r;
  EXPECT_FALSE(r.add(route(Method::Get, "")));
  EXPECT_FALSE(r.add(route(Method::Get, "no-slash")));
  EXPECT_FALSE(r.add(route(Method::Get, "/:")));
  EXPECT_FALSE(r.add(route(Method::Get, "/a/*/b")));
  EXPECT_FALSE(r.add(route(Method::Get, "/a/b*c")));
  EXPECT_EQ(r.size(), 0u);
}

TEST(RouterTest, MatchesLiteral) {
  Router r;
  EXPECT_TRUE(r.add(route(Method::Get, "/hello")));
  const MatchResult m = r.match(Method::Get, "", "/hello");
  EXPECT_TRUE(m.matched);
  EXPECT_EQ(m.route->pattern, "/hello");
  EXPECT_TRUE(m.params.empty());
}

TEST(RouterTest, MissesUnregisteredPath) {
  Router r;
  EXPECT_TRUE(r.add(route(Method::Get, "/hello")));
  EXPECT_FALSE(r.match(Method::Get, "", "/goodbye").matched);
  EXPECT_FALSE(r.match(Method::Get, "", "/hello/extra").matched);
  EXPECT_FALSE(r.match(Method::Post, "", "/hello").matched);
}

TEST(RouterTest, CapturesParams) {
  Router r;
  EXPECT_TRUE(r.add(route(Method::Get, "/users/:id")));
  const MatchResult m = r.match(Method::Get, "", "/users/42");
  EXPECT_TRUE(m.matched);
  ASSERT_EQ(m.params.size(), 1u);
  EXPECT_EQ(m.params[0].name, "id");
  EXPECT_EQ(m.params[0].value, "42");
}

TEST(RouterTest, CapturesMultipleParams) {
  Router r;
  EXPECT_TRUE(r.add(route(Method::Get, "/a/:x/b/:y")));
  const MatchResult m = r.match(Method::Get, "", "/a/1/b/2");
  EXPECT_TRUE(m.matched);
  ASSERT_EQ(m.params.size(), 2u);
  EXPECT_EQ(m.params[0].value, "1");
  EXPECT_EQ(m.params[1].value, "2");
  EXPECT_FALSE(r.match(Method::Get, "", "/a/1/b").matched);
}

TEST(RouterTest, StaticBeatsParam) {
  Router r;
  EXPECT_TRUE(r.add(route(Method::Get, "/files/:name")));
  EXPECT_TRUE(r.add(route(Method::Get, "/files/readme")));
  const MatchResult m = r.match(Method::Get, "", "/files/readme");
  EXPECT_TRUE(m.matched);
  EXPECT_EQ(m.route->pattern, "/files/readme");
  const MatchResult p = r.match(Method::Get, "", "/files/other");
  EXPECT_TRUE(p.matched);
  EXPECT_EQ(p.route->pattern, "/files/:name");
}

TEST(RouterTest, ParamBeatsWildcard) {
  Router r;
  EXPECT_TRUE(r.add(route(Method::Get, "/files/*")));
  EXPECT_TRUE(r.add(route(Method::Get, "/files/:name")));
  const MatchResult m = r.match(Method::Get, "", "/files/x");
  EXPECT_TRUE(m.matched);
  EXPECT_EQ(m.route->pattern, "/files/:name");
  const MatchResult w = r.match(Method::Get, "", "/files/a/b");
  EXPECT_TRUE(w.matched);
  EXPECT_EQ(w.route->pattern, "/files/*");
}

TEST(RouterTest, WildcardMatchesEmptyRemainder) {
  Router r;
  EXPECT_TRUE(r.add(route(Method::Get, "/files/*")));
  EXPECT_TRUE(r.match(Method::Get, "", "/files").matched);
  EXPECT_TRUE(r.match(Method::Get, "", "/files/").matched);
}

TEST(RouterTest, AllMatchesAnyMethod) {
  Router r;
  EXPECT_TRUE(r.add(route(Method::All, "/any")));
  EXPECT_TRUE(r.match(Method::Post, "", "/any").matched);
  EXPECT_TRUE(r.match(Method::Delete, "", "/any").matched);
}

TEST(RouterTest, SpecificBeatsAll) {
  Router r;
  EXPECT_TRUE(r.add(route(Method::All, "/any")));
  EXPECT_TRUE(r.add(route(Method::Post, "/any", 100)));
  const MatchResult m = r.match(Method::Post, "", "/any");
  EXPECT_TRUE(m.matched);
  EXPECT_EQ(m.route->timeoutMs, 100);
  const MatchResult g = r.match(Method::Get, "", "/any");
  EXPECT_TRUE(g.matched);
  EXPECT_EQ(g.route->timeoutMs, -1);
}

TEST(RouterTest, CustomTokensMatchByToken) {
  Router r;
  RouteEntry e{Method::Custom, "PURGE", "/cache", -1};
  EXPECT_TRUE(r.add(e));
  EXPECT_TRUE(r.match(Method::Custom, "PURGE", "/cache").matched);
  EXPECT_FALSE(r.match(Method::Custom, "BAN", "/cache").matched);
  EXPECT_FALSE(r.match(Method::Get, "", "/cache").matched);
}

TEST(RouterTest, ReregisterReplacesTimeout) {
  Router r;
  EXPECT_TRUE(r.add(route(Method::Get, "/t", 100)));
  EXPECT_TRUE(r.add(route(Method::Get, "/t", 200)));
  EXPECT_EQ(r.size(), 1u);
  EXPECT_EQ(r.match(Method::Get, "", "/t").route->timeoutMs, 200);
}

TEST(RouterTest, RemoveDropsOnlyTheNamedMethod) {
  Router r;
  EXPECT_TRUE(r.add(route(Method::Get, "/t")));
  EXPECT_TRUE(r.add(route(Method::Post, "/t")));
  EXPECT_TRUE(r.remove(Method::Get, "", "/t"));
  EXPECT_FALSE(r.match(Method::Get, "", "/t").matched);
  EXPECT_TRUE(r.match(Method::Post, "", "/t").matched);
  EXPECT_FALSE(r.remove(Method::Get, "", "/t"));
  EXPECT_FALSE(r.remove(Method::Get, "", "/missing"));
}

TEST(RouterTest, RootPath) {
  Router r;
  EXPECT_TRUE(r.add(route(Method::Get, "/")));
  EXPECT_TRUE(r.match(Method::Get, "", "/").matched);
}

}  // namespace


TEST(RouterTest, AllowedMethodsListsWhatIsRegisteredAtThePath) {
  Router r;
  RouteEntry get;
  get.method = Method::Get;
  get.pattern = "/a/:id";
  ASSERT_TRUE(r.add(get));
  RouteEntry post;
  post.method = Method::Post;
  post.pattern = "/a/:id";
  ASSERT_TRUE(r.add(post));
  RouteEntry custom;
  custom.method = Method::Custom;
  custom.customMethod = "PURGE";
  custom.pattern = "/a/fixed";
  ASSERT_TRUE(r.add(custom));
  RouteEntry wild;
  wild.method = Method::Put;
  wild.pattern = "/files/*";
  ASSERT_TRUE(r.add(wild));
  RouteEntry all;
  all.method = Method::All;
  all.pattern = "/any";
  ASSERT_TRUE(r.add(all));
  using V = std::vector<std::string>;
  EXPECT_EQ(r.allowedMethods("/a/42"), (V{"GET", "HEAD", "POST"}));
  // The static sibling and the param node both apply to /a/fixed.
  EXPECT_EQ(r.allowedMethods("/a/fixed"), (V{"GET", "HEAD", "POST", "PURGE"}));
  EXPECT_EQ(r.allowedMethods("/files/x/y"), (V{"PUT"}));
  EXPECT_EQ(r.allowedMethods("/files"), (V{"PUT"}));
  EXPECT_EQ(r.allowedMethods("/any"),
            (V{"DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT", "TRACE"}));
  EXPECT_TRUE(r.allowedMethods("/nothing").empty());
  EXPECT_TRUE(r.allowedMethods("/a").empty());
  EXPECT_STREQ(methodToken(Method::All), "*");
  EXPECT_STREQ(methodToken(Method::Custom), "");
}
