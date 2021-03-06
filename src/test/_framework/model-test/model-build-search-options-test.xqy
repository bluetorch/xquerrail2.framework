xquery version "1.0-ml";
module namespace test = "http://github.com/robwhitby/xray/test";
import module namespace assert = "http://github.com/robwhitby/xray/assertions" at "/xray/src/assertions.xqy";

import module namespace setup = "http://xquerrail.com/test/setup" at "../../../test/_framework/setup.xqy";
import module namespace app = "http://xquerrail.com/application" at "../../../main/_framework/application.xqy";
import module namespace config = "http://xquerrail.com/config" at "../../../main/_framework/config.xqy";
import module namespace domain = "http://xquerrail.com/domain" at "../../../main/_framework/domain.xqy";
import module namespace model = "http://xquerrail.com/model/base" at "../../../../main/_framework/base/base-model.xqy";
import module namespace search = "http://marklogic.com/appservices/search" at "/MarkLogic/appservices/search/search.xqy";

declare option xdmp:mapping "false";

declare variable $TEST-COLLECTION := "model-build-search-options-test";

declare variable $TEST-APPLICATION :=
<application xmlns="http://xquerrail.com/config">
  <base>/main</base>
  <config>/test/_framework/model-test/_config</config>
</application>
;

declare variable $instance4 :=
<model4 xmlns="http://xquerrail.com/app-test">
  <id>model4-id</id>
  <name>model4-name</name>
  <tag title="model4-title"/>
</model4>
;

declare %test:setup function setup() as empty-sequence()
{
  let $_ := (app:reset(), app:bootstrap($TEST-APPLICATION))
  let $model4 := domain:get-model("model4")
  let $_ := model:create($model4, $instance4, $TEST-COLLECTION)
  return
    ()
};

declare %test:teardown function teardown() as empty-sequence()
{
  xdmp:invoke-function(
    function() {
      xdmp:collection-delete($TEST-COLLECTION),
      xdmp:commit()
    },
    <options xmlns="xdmp:eval">
      <transaction-mode>update</transaction-mode>
    </options>
  )
};

declare %test:case function model-buils-search-options-element-attribute-sort-test() {
  let $model4 := domain:get-model("model4")
  let $params := map:new()
  let $tag-title-field := $model4/domain:element[@name eq 'tag']/domain:attribute[@name eq 'title']
  let $search-options := model:build-search-options($model4, $params)
  let $title-sort-order-asending := $search-options/search:operator/search:state[@name eq model:search-sort-state($tag-title-field, "ascending")]
  let $title-sort-order-descending := $search-options/search:operator/search:state[@name eq model:search-sort-state($tag-title-field, "descending")]
  return (
    assert:not-empty($model4/domain:element[@name eq 'tag']/domain:attribute[@name eq 'title']),
    assert:not-empty($model4/domain:element[@name eq 'tag']/domain:attribute[@name eq 'title']/domain:navigation[@searchable eq 'true' and @sortable eq 'true']),
    assert:not-empty($search-options),
    assert:equal(fn:name($search-options), "search:options"),
    assert:equal($title-sort-order-asending/search:sort-order/@direction/fn:string(), "ascending"),
    assert:equal($title-sort-order-asending/search:sort-order/search:element/@name/fn:string(), "tag"),
    assert:equal($title-sort-order-asending/search:sort-order/search:attribute/@name/fn:string(), "title"),
    assert:equal($title-sort-order-descending/search:sort-order/@direction/fn:string(), "descending"),
    assert:equal($title-sort-order-descending/search:sort-order/search:element/@name/fn:string(), "tag"),
    assert:equal($title-sort-order-descending/search:sort-order/search:attribute/@name/fn:string(), "title")
  )
};
