// Router unit tests: the trie is the "build now or pay later" item from the
// implementation plan, so it gets the deepest coverage in the C++ suite.
#include <gtest/gtest.h>

#include "engine/Router.h"

using namespace nitroserver;

namespace {

RouteEntry route(Method m, const std::string& pattern, int64_t timeout = -1) {
  return RouteEntry{m, "", pattern, timeout};
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
  EXPECT_EQ(m.route.pattern, "/hello");
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
  EXPECT_EQ(m.route.pattern, "/files/readme");
  const MatchResult p = r.match(Method::Get, "", "/files/other");
  EXPECT_TRUE(p.matched);
  EXPECT_EQ(p.route.pattern, "/files/:name");
}

TEST(RouterTest, ParamBeatsWildcard) {
  Router r;
  EXPECT_TRUE(r.add(route(Method::Get, "/files/*")));
  EXPECT_TRUE(r.add(route(Method::Get, "/files/:name")));
  const MatchResult m = r.match(Method::Get, "", "/files/x");
  EXPECT_TRUE(m.matched);
  EXPECT_EQ(m.route.pattern, "/files/:name");
  const MatchResult w = r.match(Method::Get, "", "/files/a/b");
  EXPECT_TRUE(w.matched);
  EXPECT_EQ(w.route.pattern, "/files/*");
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
  EXPECT_EQ(m.route.timeoutMs, 100);
  const MatchResult g = r.match(Method::Get, "", "/any");
  EXPECT_TRUE(g.matched);
  EXPECT_EQ(g.route.timeoutMs, -1);
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
  EXPECT_EQ(r.match(Method::Get, "", "/t").route.timeoutMs, 200);
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
