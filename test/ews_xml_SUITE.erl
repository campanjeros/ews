-module(ews_xml_SUITE).
-include_lib("common_test/include/ct.hrl").

%% CT functions
-export([suite/0, groups/0, all/0]).

%% Tests
-export([tag_with_multiple_namespaces/1,
         namespace_owerwriting/1
        ]).

suite() -> [{timetrap, {seconds, 20}}].

groups() ->
    [{xml_test, [shuffle],
      [tag_with_multiple_namespaces,
       namespace_owerwriting
      ]}].

all() ->
    [{group, xml_test}].

tag_with_multiple_namespaces(_Config) ->
    XMLString = "<a:test xmlns:a=\"ns-a\" xmlns:b=\"ns-b\" ><b:test2/></a:test>",
    Terms = ews_xml:decode(XMLString),
    Terms = [{{"ns-a", "test"}, [],
             [{{"ns-b","test2"}, [], []}]}].

namespace_owerwriting(_Config) ->
    XMLString = "<test xmlns=\"a\" ><test2 xmlns=\"b\" /></test>",
    Terms = ews_xml:decode(XMLString),
    Terms = [{{"a","test"},[],[{{"b","test2"},[],[]}]}].
