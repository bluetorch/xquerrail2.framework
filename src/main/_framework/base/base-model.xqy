xquery version "1.0-ml";
(:~
: Model : Base
: @author Gary Vidal
: @version  1.0
 :)

module namespace model = "http://xquerrail.com/model/base";

import module namespace search = "http://marklogic.com/appservices/search" at "/MarkLogic/appservices/search/search.xqy";

import module namespace context = "http://xquerrail.com/context" at "../context.xqy";

import module namespace domain = "http://xquerrail.com/domain" at "../domain.xqy";

import module namespace config = "http://xquerrail.com/config" at "../config.xqy";

import module namespace functx = "http://www.functx.com" at "/MarkLogic/functx/functx-1.0-doc-2007-01.xqy";

import module namespace sem = "http://marklogic.com/semantics" at "/MarkLogic/semantics.xqy";

declare namespace as = "http://www.w3.org/2005/xpath-functions";

declare default collation "http://marklogic.com/collation/codepoint";

(:Options Definition:)
declare option xdmp:mapping "false";


declare variable $binary-dependencies := map:map();
declare variable $reference-dependencies := map:map();
declare variable $current-identity := ();

(:Stores a cache of any references resolved :)
declare variable $REFERENCE-CACHE := map:map();
declare variable $INSTANCE-CACHE  := map:map();
declare variable $FUNCTION-CACHE  := map:map();

declare variable $EXPANDO-PATTERN := "\$\((\i\c*(/@?\i\c*)*)\)";

declare variable $DEFAULT-PAGE-SIZE := 20;

declare function model:uuid-string(
) as xs:string {
  model:uuid-string(xdmp:random())
};

declare function model:uuid-string(
  $seed as xs:integer?
) as xs:string {
  let $hash := (:Assume FIPS is installed by default:)
    if(fn:tokenize(xdmp:version(),"\.")[1] > "6") then
      xdmp:apply(xdmp:function(xs:QName("xdmp:hmac-sha1")),"uuid",fn:string($seed))
    else
      xdmp:apply(xdmp:function(xs:QName("xdmp:sha1")),fn:string($seed))
  return fn:replace($hash,"(\c{8})(\c{4})(\c{4})(\c{4})(\c{12})","$1-$2-$3-$4-$5")
};

(:~
 : Returns the current-identity field for use when instance does not have an existing identity
 :)
declare function  model:get-identity(
) {
  if(fn:exists($current-identity))
  then $current-identity
  else
    let $id := model:generate-uuid()
    return (
      xdmp:set($current-identity,$id),
      $id
    )
};


(:~
 : Generates a UUID based on the SHA1 algorithm.
 : Wallclock will be used to make the UUIDs sortable.
 : Note when calling function the call will reset the current-identity.
 :)
declare function model:generate-uuid(
  $seed as xs:integer?
) as xs:string {
  let $guid := model:uuid-string($seed)
  return (
    xdmp:set($current-identity,$guid),
    $guid
  )
};
(:~
 :  Generates a UUID based on randomization function
 :)
declare function model:generate-uuid() as xs:string
{
   switch(config:identity-scheme())
    case "id" return model:generate-fnid(xdmp:random())
    default return model:generate-uuid(xdmp:random())
};

(:~
 : Creates an ID for an element using fn:generate-id.   This corresponds to the config:identity-scheme
 :)
declare function model:generate-fnid($instance as item()) {
  if($instance instance of element()) then fn:generate-id($instance)
  else fn:generate-id(<_instance_>{$instance}</_instance_>)
};

(:~
 : Creates a sequential id from a seed that monotonically increases on each call.
 : This is not a performant id pattern as randomly generated one.
~:)
declare function model:generate-sequenceid($seed as xs:integer) {
   ()
};

(:~
 :  Builds an IRI from a string value if the value is curied, then the iri is expanded to its canonical iri
 :  @param $uri - Uri to format. Variables should be in form $(var-name)
 :  @param $model -  Model to use for reference
 :  @param $instance - Instance of asset can be map or instance of element from domain
 :)
declare function model:generate-iri(
  $uri as xs:string,
  $model as element(domain:model),
  $instance as item()
) {
  let $token-pattern := $EXPANDO-PATTERN
  let $patterns := fn:analyze-string($uri,$token-pattern)
  let $expanded :=
    fn:string-join(
      for $p in $patterns/*
      return
      typeswitch($p)
        case element(as:non-match) return $p
        case element(as:match) return
          let $field-name := fn:data($p/*:group[@nr=1]/text()[1])
          let $field := $model//(domain:attribute|domain:element)[@name eq $field-name]
          let $data := domain:get-field-value($field,$instance)
          return
            if($data) then fn:data($data)
            else if($field/@type eq "identity") then model:get-identity()
            else fn:error(xs:QName("EMPTY-URI-VARIABLE"),"URI Variables must not be empty",$field-name)
        default return ""
     ,""
    )
  let $is-curied := fn:matches($expanded,"\i\c*:\i\c")
  return
    if($is-curied) then sem:curie-expand($expanded,domain:declared-namespaces-map($model))
    else $expanded
};

(:~
 :  Builds a URI with variable placeholders
 :  @param $uri - Uri to format. Variables should be in form $(var-name)
 :  @param $model -  Model to use for reference
 :  @param $instance - Instance of asset can be map or instance of element from domain
 :)
declare function model:generate-uri(
  $uri as xs:string,
  $model as element(domain:model),
  $instance as item()
) {
  let $token-pattern := $EXPANDO-PATTERN
  let $patterns := fn:analyze-string($uri,$token-pattern)
  return
    fn:string-join(
      for $p in $patterns/*
      return
      switch(fn:local-name($p))
        case "non-match" return $p
        case "match" return
          let $field-name := fn:data($p/*:group[@nr=1])
          let $field := $model//(domain:attribute|domain:element)[@name eq $field-name]
          let $data := domain:get-field-value($field,$instance)
          return
            if($data) then $data
            else if($field/@type eq "identity") then model:get-identity()
            else fn:error(xs:QName("EMPTY-URI-VARIABLE"),"URI Variables must not be empty",$field-name)
        default return ""
      ,""
    )
};

(:~
 : Creates a series of collections based on the existing update
 :)
declare function build-collections(
  $collections as xs:string*,
  $model as element(domain:model),
  $instance as item()
) {
  for $c in $collections
  return
    model:generate-uri($c,$model,$instance)
};

(:~
: This function accepts a doc node and converts to an element node and
: returns the first element node of the document
: @param - $doc - the doc
: @return - the root as a node
:)
declare function model:get-root-node(
  $model as element(domain:model),
  $doc as node()
) as node() {
  if($doc instance of document-node()) then $doc/* else $doc
};

(:~
: This function checks the parameters for an identifier that signifies the instance of a model
: @param - $model - domain model of the content
: @param - $params - parameters of content that pertain to the domain model
: @return a identity or uuid value (repsective) for identifying the model instance
:)
declare function model:get-id-from-params(
  $model as element(domain:model),
  $params as item()*
) as xs:string? {
  let $id-field := domain:get-model-identity-field($model)
  return
    domain:get-field-value($id-field,$params)
};

(:~
 : Gets only the params for a given model
 : @param - $model - is the model for the given params
 : @param - $params - parameters of content that pertain to the domain model
 : @param - $strict - boolean value on whether to be strict or not
 : @deprecated
 :)
declare function model:get-model-params(
  $model as element(domain:model),
  $params as map:map,
  $strict as xs:boolean
) {
  fn:error(xs:QName("DEPRECATED"),"Function is deprecated"),
  let $model-params := map:map()
  return (
    for $f in $model/(domain:element|attribute)
    return (
      map:put($model-params,$f/@name,domain:get-param-value($params,$f/@name)),
      map:delete($model-params,$f/@name)
    ),
    if(map:count($params) gt 0 and $strict) then
      fn:error(xs:QName("INVALID-PARAMETERS"),"Additional Parameters are not allowed in strict mode")
    else
      (),
    $model-params
  )
};

(:~
 :  Creates a new instance of an asset and returns that instance but does not persist in database
 :)
declare function model:new(
  $model as element(domain:model)
) {
  model:new($model,map:map())
};

(:~
 :  Creates a new instance of a model but does not persisted.
 :)
declare function model:new(
  $model as element(domain:model),
  $params as item()
) {
  let $identity := xs:string(domain:get-field-value(domain:get-model-identity-field($model), $params))
  let $identity :=
    if ($identity) then $identity
    else model:generate-uuid()
  (:let $identity := model:generate-uuid():)
  return model:recursive-create($model,$params)
};

(:~
 : Creates any binary nodes associated with model instance
 :)
declare function model:create-binary-dependencies(
  $identity as xs:string,
  $instance as element()
) {
  model:create-binary-dependencies($identity,$instance,xdmp:default-permissions(),xdmp:default-collections())
};

(:~
 :  Inserts any binary dependencies created from binary|file type elements
 :)
declare function model:create-binary-dependencies(
  $identity as xs:string,
  $instance as element(),
  $permissions as element(sec:permission)*,
  $collections as xs:string*
) {
  for $k in map:keys($binary-dependencies)
  return (
    xdmp:document-insert(
      $k,
      domain:get-param-value($binary-dependencies,$k),
      xdmp:default-permissions(),
      $identity
    ), (:~Cleanup map :)
    map:delete($binary-dependencies,$k)
  )
};

(:~
 : Caches reference from a created instance so a reference can be formed without a seperate transaction
 :)
declare function model:create-reference-cache(
  $model as element(domain:model),
  $instance
) {
  let $cache-key-field := domain:get-model-key-field($model)
  let $cache-keylabel-field := domain:get-model-keyLabel-field($model)
  let $cache-key-value := domain:get-field-value($cache-key-field,$instance)
  let $cache-keylabel-value := domain:get-field-value($cache-keylabel-field,$instance)
  let $reference :=
    element {domain:get-field-qname($model)} {
      attribute ref-type { "model" },
      attribute ref-id   {$cache-key-value},
      attribute ref      { $model/@name},
      text {$cache-keylabel-value}
    }
  return (
    model:set-cache-reference($model,($cache-key-value,$cache-keylabel-value),$reference)
  )
};

(:~
 : Creates a model for a given domain
 : @param - $model - is the model for the given params
 : @param - $params - parameters of content that pertain to the domain model
 : @returns element
 :)
declare function model:create(
  $model as element(domain:model),
  $params as item()
) as element()? {
  model:create($model, $params, xdmp:default-collections())
};

(:~
 : Creates a model for a given domain
 : @param - $model - is the model for the given params
 : @param - $params - parameters of content that pertain to the domain model
 : @returns element
 :)
declare function model:create(
  $model as element(domain:model),
  $params as item(),
  $collections as xs:string*
) as element()? {
  model:create($model, $params, $collections, xdmp:default-permissions())
};

(:~
 : Creates a model for a given domain
 : @param - $model - is the model for the given params
 : @param - $params - parameters of content that pertain to the domain model
 : @returns element
 :)
declare function model:create(
  $model as element(domain:model),
  $params as item()*,
  $collections as xs:string*,
  $permissions as element(sec:permission)*
) as element()? {
  let $params := domain:fire-before-event($model,"create",$params)
  let $current := model:get($model,$params)
  return
    (: Check if the document exists  first before trying to create it :)
    if ($current) then
      fn:error(xs:QName("DOCUMENT-EXISTS"), text{"The document already exists.", "model:", $model/@name, "- key:", domain:get-field-value(domain:get-model-keyLabel-field($model), $current)})
    else
      let $update := model:new($model,$params)
      let $identity := xs:string(domain:get-field-value(domain:get-model-identity-field($model), $update))
      let $computed-collections :=
        model:build-collections(
          ($model/domain:collection),
          $model,
          $update
        )
      let $collections := fn:distinct-values(($computed-collections,$collections))
      let $computed-permissions := functx:distinct-deep((domain:get-permissions($model),$permissions))
      let $name := $model/@name
      let $persistence := $model/@persistence
      return (
        switch($persistence)
          (: Creation for document persistence :)
          case "document" return
            let $path := $model/domain:document/text()
            let $doc := fn:doc($path)
            let $root-node := fn:data($model/domain:document/@root)
            let $root-namespace := domain:get-field-namespace($model)
            return (
              if ($doc) then
                let $root :=  model:get-root-node($model,$doc)
                return
                  if($root) then
                  (: create the instance of the model in the document :)
                    (
                      xdmp:node-insert-child($root,$update),
                      xdmp:document-set-permissions(xdmp:node-uri($root),$computed-permissions)
                    )
                  else fn:error(xs:QName("ROOT-MISSING"),"Missing Root Node",$doc)
              else (
                xdmp:document-insert(
                  $path,
                  element { fn:QName($root-namespace,$root-node) } { $update },
                  $computed-permissions,
                  $collections
                )
              ),
              model:create-binary-dependencies($identity,$update)
            )
          (: Creation for directory persistence :)
          case "directory" return
            let $field-id := domain:get-field-value(domain:get-model-identity-field($model),$update)
            let $base-path := $model/domain:directory/text()
            let $sub-path := $model/domain:directory/@subpath
            let $ext-path :=
              if($sub-path) then
                model:generate-uri($sub-path,$model,$update)
              else ""
            let $path := model:normalize-path(
              fn:concat(
                $base-path,
                $ext-path,
                "/",
                $field-id,
                ".xml"
              )
            )
            return (
              xdmp:document-insert(
                $path,
                $update,
                $computed-permissions,
                $collections
              ),
              model:create-binary-dependencies($identity,$update)
            )
          (:Singleton Persistence is good for configuration Files :)
          case "singleton" return
            let $field-id := domain:get-field-value($model/(domain:element|domain:attribute)[@type eq "identity"],$update)
            let $path := $model/domain:document/text()
            let $doc := fn:doc($path)
            let $root-namespace := domain:get-field-namespace($model)
            return (
              if ($doc) then
                (: create the instance of the model in the document :)
                xdmp:node-replace(model:get-root-node($model,$doc),$update)
              else
                xdmp:document-insert(
                  $path,
                  element { fn:QName($root-namespace,$model/@name) } { $update },
                  $permissions,
                  $collections
                ),
                model:create-binary-dependencies($field-id,$update)
            )
          case "abstract"
            return fn:error(xs:QName("PERSISTENCE-ERROR"),"Cannot Persist Abstract Objects",$model/@name)
          default
            return fn:error(xs:QName("PERSISTENCE-ERROR"),"No document persistence defined for create",$model/@name),
          domain:fire-after-event($model,"create",$update)
       )
};

(:~
 : Returns if the passed in _query param will return a model exists
 :)
declare function model:exists(
  $model as element(domain:model),
  $params as item()
) as xs:boolean {
  let $namespace := domain:get-field-namespace($model)
  let $localname := fn:data($model/@name)
  return
    xdmp:exists(
      cts:search(fn:doc(),
        cts:element-query(
          fn:QName($namespace,$localname),
          cts:and-query((
            domain:get-base-query($model),
            domain:get-param-value($params,"_query")
          ))
        )
      )
    )
};

(:~
: Retrieves a model document by id
: @param $model the model of the document
: @param $params the values to pull the id from
: @return the document
 :)
declare function model:get(
   $model as element(domain:model),
   $params as item()
) as element()? {
  (: Get document identifier from parameters :)
  (: Retrieve document identity and namspace to help build query :)
  if($model/@persistence = "abstract") then fn:error(xs:QName("MODEL-ERROR"), "Cannot Retrieve Model whose persistence is abstract",$model/@name) else (),
  let $uri :=
    if($params instance of map:map or
    $params instance of node() or
    $params instance of json:object or
    $params instance of json:array) then
      domain:get-param-value($params,"uri")
    else
      ()
  let $identity-map :=
    if($params instance of map:map or
    $params instance of node() or
    $params instance of json:object or
    $params instance of json:array) then
    $params
    else
      let $identity-field-name := domain:get-model-identity-field-name($model)
      let $keylabel-field := domain:get-model-keyLabel-field($model)
      return
      map:new((
        map:entry($identity-field-name, $params),
        map:entry($keylabel-field/@name, $params)
      ))

  let $persistence := $model/@persistence
  let $identity-query :=
    cts:and-query((
      domain:get-base-query($model),
      cts:or-query((
         domain:get-identity-query($model, $identity-map),
         domain:get-keylabel-query($model, $identity-map),
         if($uri) then cts:document-query($uri) else ()
      ))
    ))
  let $results :=
    switch($persistence)
      case "directory" return
        cts:search(fn:collection()/element(), $identity-query)
      case "document" return
        fn:doc($model/domain:document)/element()/element()[cts:contains(., $identity-query)]
      default return
        fn:error(xs:QName("MODEL-GET-ERROR"),"Cannot get model with persistence",$persistence)
  return $results
};

(:~
: Retrieves a model document by id
: @param $model the model of the document
: @param $params the values to pull the id from
: @return the document
 :)
declare function model:reference-by-keylabel(
   $model as element(domain:model),
   $params (:as map:map:)
) as element()? {
    (: Get document identifier from parameters :)
    (: Retrieve document identity and namspace to help build query :)
    let $name := fn:data($model/@name)
    let $id-field   := domain:get-model-identity-field-name($model)
    let $key-field := fn:data($model/@keyLabel)
    let $key-field-def := $model//(domain:element|domain:attribute)[@name eq $key-field]
    let $model-name := fn:data($key-field-def/ancestor::domain:model/@name)
    let $key-value := domain:get-field-id($key-field-def)
    let $nameSpace := domain:get-field-namespace($model)
    let $value := domain:get-field-value($model,$params)
    let $stmt :=
      fn:normalize-space(fn:string(
      <stmt>cts:search({
                    (: Build a query to search within the give document :)
                    if ($model/@persistence = 'document') then
                        let $rootNode := fn:data($model/domain:document/@root)
                        (: if namespaces are given use it :)
                        let $xpath :=
                            if($nameSpace) then
                               fn:concat("/*:", $rootNode, "[fn:namespace-uri(.) = '", $nameSpace, "']/*:", $name, "[fn:namespace-uri(.) = '", $nameSpace, "']")
                            else
                                fn:concat("/", $rootNode, "/", $name)
                        return
                            (: Create a constraint :)
                            fn:concat('fn:doc("', $model/domain:document/text() , '")', $xpath )
                    else
                        (: otherwise for document persistance search against the proper root node :)
                        fn:concat("/*:",$name, "[fn:namespace-uri(.) = '", $nameSpace, "']")
                },
                cts:or-query((
                    if($model/@persistence = "document") then
                        if($key-field-def instance of element(domain:attribute))
                        then cts:element-attribute-value-query(fn:QName("{$nameSpace}","{$model-name}"),fn:QName("","{$id-field}"),"{$value}","exact")
                        else cts:element-value-query(fn:QName("{$nameSpace}","{$key-field}"),"{$value}")
                    else
                    if($key-field-def instance of element(domain:attribute))
                    then cts:element-attribute-range-query(fn:QName("{$nameSpace}","{$model-name}"),fn:QName("","{$id-field}"),"=","{$value}","exact")
                    else (
                        cts:element-range-query(fn:QName("{$nameSpace}","{$key-field}"),"=","{$value}"),
                        cts:element-range-query(fn:QName("{$nameSpace}","{$id-field}"),"=", "{$value}")
                    )
                )), ("filtered"))
        </stmt>))
    let $exprValue := xdmp:value($stmt)
    return (
        (: Execute statement :)
        xdmp:log(("model:getByReference::",$stmt),"debug"),
        $exprValue
        )
};

declare function model:update-partial(
  $model as element(domain:model),
  $params as item()
) {
  model:update-partial($model,$params,xdmp:default-collections())
};
(:~
 : Creates an partial update statement for a given model.
 :)
declare function model:update-partial(
  $model as element(domain:model),
  $params as item(),
  $collections as xs:string*
) {
  model:update($model,$params,$collections,fn:true())
};

declare function model:parse-patch-path(
  $path as xs:string
) {
  let $match := fn:analyze-string($path, "(\[)(\d+)(\]$)")
  return
    element result {
      element path {$match/*:non-match/text()},
      if (fn:count($match/*:match/*:group) eq 3) then
        element index {
          if ($match/*:match/*:group[2] gt 0) then
            $match/*:match/*:group[2]/text()
          else
            fn:error(xs:QName("INVALID-POSITION"), text{"Invalid position in path", $path})
        }
      else
        ()
    }
};

declare function model:patch(
  $model as element(domain:model),
  $instance as element(),
  $params as item()*
) {
  let $instance := model:convert-to-map($model, $instance)
  return (
    $params ! (
      let $item := .
      let $operation := map:get($item, "op")
      let $path := map:get($item, "path")
      let $value := map:get($item, "value")
      let $path := model:parse-patch-path($path)
      let $field := domain:get-model-field($model, $path/path)
      let $field :=
        if (fn:exists($field)) then $field
        else fn:error(xs:QName("FIELD-NOT-FOUND"), text{"Could not find field from path", $path, "in model", $model/@name})
      let $key := domain:get-field-name-key($field)
      return
        if (fn:empty($field)) then
          (xdmp:log(text{"Cannot find field from", $path}, "info"))
        else
          if ($operation eq "add") then
          (
            if (domain:field-is-multivalue($field)) then
              if (fn:exists($path/index)) then
                map:put(
                  $instance,
                  $key,
                  fn:insert-before(
                    map:get($instance, $key), xs:integer($path/index), $value
                  )
                )
              else
                map:put($instance, $key, (map:get($instance, $key), $value))
            else
              map:put($instance, $key, $value)
          )
          else if ($operation eq "remove") then
          (
            if (fn:exists($path/index)) then
              map:put($instance, $key, (fn:remove(map:get($instance, $key), $path/index)))
            else
              map:delete($instance, $key)
          )
          else if ($operation eq "replace") then
          (
            if (fn:exists($path/index)) then
              map:put(
                $instance, $key,
                (
                  fn:subsequence(map:get($instance, $key), 1, ($path/index - 1)),
                  $value,
                  fn:subsequence(map:get($instance, $key), ($path/index + 1))
                )
              )
            else
              map:put($instance, $key, $value)
          )
          else if ($operation eq "test") then
          (
            if (fn:exists($path/index) and fn:subsequence(map:get($instance, $key), $path/index, 1) eq $value) then
              ()
            else if (map:get($instance, $key) eq $value) then
              ()
            else
              fn:error(xs:QName("PATCH-TEST-FAILED"), text{"Test failed", "path", $path, "value", $value})
          )
          else
          (fn:error(xs:QName("OPERATION-NOT-IMPLEMENTED"), text{"Operation", $operation, "not implemented"}))
    )
    ,
    $instance
  )
};

(:~
 : Overloaded method to support existing controller functions for adding collections
 :)
declare function model:update(
  $model as element(domain:model),
  $params as item()
) {
  model:update($model,$params,xdmp:default-collections())
};

(:~
 : Overloaded method to support existing controller functions for adding collections and partial update
 :)
declare function model:update(
  $model as element(domain:model),
  $params as item(),
  $collections as xs:string*
) {
  model:update($model,$params,$collections,fn:false())
};


(:~
 : Creates an update statement for a given model.
 : @param $model - domain element for the given update
 : @param $params - List of update parameters for a given update, the uuid element must be present in the document
 : @param $collections - Additional collections to add to document
 : @param $partial - if the update should pull the values of the current-node if no params key is present
 :)
declare function model:update(
  $model as element(domain:model),
  $params as item(),
  $collections as xs:string*,
  $partial as xs:boolean
) as element() {
  let $params := domain:fire-before-event($model,"update",$params)
  let $current := model:get($model,$params)
  let $id := $model//(domain:container|domain:element|domain:attribute)[@identity eq "true"]/@name
  let $identity-field := $model//(domain:element|domain:attribute)[@identity eq "true" or @type eq "identity"]
  let $identity := (domain:get-field-value($identity-field,$current))[1]
  let $persistence := fn:data($model/@persistence)
  return
    if($current) then
      let $build := model:recursive-create($model,$current,$params,$partial)
      let $computed-collections :=
        model:build-collections(
          ($model/domain:collection, domain:get-param-value($params,"_collection"),$collections),
          $model,
          $build
        )
      return (
        (:if(fn:count($validation) > 0) then
            <error type="validation">
            {$validation}
            </error>
        else:)
        if($persistence = "document") then
          xdmp:node-replace($current,$build)
        else if($persistence = "directory") then
          xdmp:document-insert(
            xdmp:node-uri($current),
            $build,
            functx:distinct-deep((xdmp:document-get-permissions(xdmp:node-uri($current)),domain:get-permissions($model))),
            fn:distinct-values(($collections,$computed-collections,xdmp:document-get-collections(xdmp:node-uri($current))))
          )
        else
          fn:error(xs:QName("UPDATE-NOT-PERSISTABLE"),"Cannot Update Model with persistence: " || $persistence,$persistence),
        model:create-binary-dependencies($identity,$current),
        domain:fire-after-event($model,"update",$build)
      )
    else
      fn:error(xs:QName("UPDATE-NOT-EXISTS"), "Trying to update a document that does not exist.")
};

declare function model:create-or-update(
  $model as element(domain:model),
  $params as item()
) {
   if(model:get($model,$params)) then model:update($model,$params)
   else model:create($model,$params)
};

(:~
 :  Returns all namespaces from domain:model and inherited from domain
 :)
declare function model:get-namespaces($model as element(domain:model)) {
   let $ns-map := map:map()
   let $nses :=
      for $kv in (
        fn:root($model)/(domain:content-namespace|domain:declare-namespace),
        $model/domain:declare-namespace
     )
      return map:put($ns-map, ($kv/@prefix),fn:data($kv/@namespace-uri))
   for $ns in map:keys($ns-map)
   return
     <ns prefix="{$ns}" namespace-uri="{domain:get-param-value($ns-map,$ns)}"/>
};

(:~
 :  Function allows for partial updates
 :)
declare function model:recursive-update-partial(
  $context as element(),
  $current as node()?,
  $updates as map:map
) {
  fn:error(xs:QName("DEPRECATED"),"Function is deprecated"),
  let $current := ()
  return $current
};

(:~
 :  Entry for recursive updates
 :)
declare function model:recursive-create(
  $model as element(domain:model),
  $updates as item()?
) {
  model:recursive-create($model, (), $updates, fn:false())
};

declare function model:recursive-create(
  $model as element(domain:model),
  $current as node()?,
  $updates as item()?,
  $partial as xs:boolean
) {
  let $mode := if (fn:exists($updates)) then "update" else "create"
  return (
    model:recursive-build($model, $current, $updates, $partial),
    model:validate-params($model, $updates, $mode)
  )
};

(:~
 :
 :)
declare function model:recursive-update(
  $context as node(),
  $current as node(),
  $updates as item()?,
  $partial as xs:boolean
) {
  fn:error(xs:QName("DEPRECATED"),"Function is deprecated. Use model:recursive-create"),
  model:recursive-build($context, $current, $updates, $partial)
};

(:~
 :
 :)
declare function model:recursive-update(
  $context as node(),
  $current as node()?,
  $updates as item()?
) {
  fn:error(xs:QName("DEPRECATED"),"Function is deprecated. Use model:recursive-create"),
  model:recursive-build( $context, $current, $updates)
};

declare function model:recursive-build(
  $context as node(),
  $current as node()?,
  $updates as item()?
) {
  model:recursive-build($context, $current, $updates, fn:false())
};

(:~
 :  Recurses the field structure and builds up a document
 :)
declare function model:recursive-build(
   $context as node(),
   $current as node()?,
   $updates as item()?,
   $partial as xs:boolean
) {
   let $type := fn:data($context/@type)
   let $key  := domain:get-field-id($context)
   let $current-value := domain:get-field-value($context,$current)
   let $default-value := fn:data($context/@default)
   let $update-value := domain:get-field-value($context, $updates)
   return
    typeswitch($context)
    case element(domain:model) return
         let $attributes :=
         (
           attribute xsi:type {domain:get-field-qname($context)},
             for $a in $context/domain:attribute
             return
                (:model:recursive-build($a, $current,$updates):)
                model:build-attribute($a,$current,$updates,$partial,fn:false())
         )
         let $ns := domain:get-field-namespace($context)
         let $nses := model:get-namespaces($context)
         return
             element {domain:get-field-qname($context)} {
                 for $nsi in $nses
                 return
                   namespace {$nsi/@prefix}{$nsi/@namespace-uri},
                 $attributes,
                 for $n in $context/(domain:element|domain:container)
                 return
                     model:recursive-build($n,$current,$updates,$partial)
             }
      (: Build out any domain Elements :)
      case element(domain:element) return
        (:Process Complex Types:)
        switch($type)
          case "reference"      return model:build-reference($context, $current, $updates, $partial)
          case "binary"         return model:build-binary($context,$current,$updates,$partial)
          case "schema-element" return model:build-schema-element($context,$current,$updates,$partial)
          case "triple"         return model:build-triple($context,$current-value,$updates,$partial)
          case "langString"     return model:build-langString($context,$current-value,$updates,$partial)
          default               return model:build-element($context, $current, $updates, $partial)
      (: Build out any domain Attributes :)
      case element(domain:attribute) return fn:error(xs:QName("BUILD-ATTRIBUTE-ERR"),"Call directly to build-attribute")
      (:model:build-attribute($context,$current,$updates,$partial, fn:false()):)
      case element(domain:triple) return model:build-triple($context,$current,$updates,$partial)
      (: Build out any domain Containers :)
      case element(domain:container) return
         let $ns := domain:get-field-namespace($context)
         let $localname := fn:data($context/@name)
         return
           element {domain:get-field-qname($context)} {
            for $a in $context/domain:attribute
            return model:build-attribute($a, $current, $updates, $partial, fn:false()),
            for $n in $context/(domain:element|domain:container)
            return
              model:recursive-build($n, $current, $updates, $partial)
            }
      (: Return nothing if the type is not of Model, Element, Attribute or Container :)
      default return fn:error(xs:QName("UNKNOWN-TYPE"),"The type of " || $type || " is unknown ",$context)
};

declare function model:build-element(
  $context as node(),
  $current as node()?,
  $updates as item(),
  $partial as xs:boolean
) {
  let $type := fn:data($context/@type)
  let $occurrence := (fn:data($context/@occurrence),"?")[1]
  let $default-value  := fn:data($context/@default)
  let $current-value := domain:get-field-value($context,$current)
  let $update-field-exists := domain:field-value-exists($context, $updates)
  (:let $update-field-value-node := domain:get-field-value-node($context, $updates):)
  let $update-value := domain:get-field-value($context, $updates)
  let $attributes :=
    for $attribute in $context/domain:attribute
    return (
      (:if (domain:field-is-multivalue($context)) then:)
        (:():)
      (:else:)
        model:build-attribute($attribute,$current, $updates,$partial,fn:false())
    )
  return
  if($type = ($domain:SIMPLE-TYPES,$domain:COMPLEX-TYPES)) then
    if(fn:exists($update-value)) then
      let $current-value := domain:get-field-value-node($context, $current)
      let $update-value := domain:get-field-value-node($context, $updates)
      for $value at $position in $update-value
        let $values := model:build-value($context, $value, $current-value)
        let $attributes :=
          if(domain:field-is-multivalue($context)) then
            for $attribute in $context/domain:attribute
            return model:build-attribute($attribute, $current-value, $update-value[$position], $partial, fn:true())
          else $attributes
        return
          if (fn:exists($attributes) or fn:exists($values) or fn:empty(fn:index-of(("?", "*"), $occurrence))) then
           element {domain:get-field-qname($context)}{
              $attributes,
              model:build-value($context,$value, $current-value)
            }
          else
            ()
    else if($partial and $update-field-exists) then
        element {domain:get-field-qname($context)}{
          $attributes
        }
    else if($partial and fn:exists($current-value)) then
      for $value in $current-value
      return
        element {domain:get-field-qname($context)}{
          $attributes,
          model:build-value($context,$value, $current-value)
        }
    else if (fn:not($update-field-exists) and fn:exists($attributes)) then
          element {domain:get-field-qname($context)} {
            $attributes
          }
    else if ($update-field-exists and fn:empty($attributes)) then
          element {domain:get-field-qname($context)} {
          }
    else
      let $values :=
        if (fn:exists($current) and fn:exists($updates) and fn:not($update-field-exists)) then
          ()
        else
          model:build-value($context, $default-value, $current-value)
      return
        if (fn:exists($attributes) or fn:exists($values) or fn:empty(fn:index-of(("?", "*"), $occurrence))) then
          element {domain:get-field-qname($context)} {
            $attributes,
            $values
          }
        else
          ()
  else if(domain:get-base-type($context) eq "instance") then
    model:build-instance($context,$current,$updates,$partial)
  else fn:error(xs:QName("UNKNOWN-TYPE"),"The type of " || $type || " is unknown ",$context)
};

(:~
 : Internal Attribute Builder
~:)
declare function model:build-attribute(
  $context as node(),
  $current as node()?,
  $updates as item(),
  $partial as xs:boolean,
  $relative as xs:boolean
) as attribute()? {
  let $type := fn:data($context/@type)
  let $current-value := domain:get-field-value($context,$current)
  let $update-value := domain:get-field-value($context, $updates, $relative)
  let $default-value := fn:data($context/@default)
  let $qname := domain:get-field-qname($context)
  let $occurrence := (fn:data($context/@occurrence),"?")[1]
  let $value := model:build-value($context, $update-value, $current-value)
  return
    if(fn:exists($update-value)) then
      attribute {$qname} {
        $value
      }
    else if($partial and fn:exists($current)) then
      attribute {$qname} {
        $current-value
      }
    else if(fn:exists($value)) then
      attribute {$qname} {
        $value
      }
    else if(fn:empty($current) and fn:exists($default-value)) then
      attribute {$qname} {
        $default-value
      }
    else if($occurrence = "+") then
      attribute {$qname} { }
    else
      ()
};
(:~
 : Builds a Reference Value by its type
 :)
declare function model:build-reference(
  $context as node(),
  $current as node()?,
  $updates as item()*,
  $partial as xs:boolean
) {
  let $type := fn:data($context/@type)
  let $key  := domain:get-field-id($context)
  let $current-value := domain:get-field-value($context,$current)
  let $default-value := fn:data($context/@default)
  let $map-values := domain:get-field-value($context,$updates)
  let $value :=
    if($map-values) then $map-values
    else if($default-value) then $default-value
    else ()
  return
    if($map-values) then
      for $value in model:build-value($context, $map-values, $current-value)
      return
        element {domain:get-field-qname($context)} {($value/(@*|node()))}
    else if($partial and $current) then
      $current-value
    else ()
};

declare function model:build-schema-element(
   $context as node(),
   $current as node()?,
   $updates as item()*,
   $partial as xs:boolean
) {
   let $type := fn:data($context/@type)
   let $key  := domain:get-field-id($context)
   let $current-value := domain:get-field-value($context,$current)
   let $default-value := fn:data($context/@default)
   let $map-values := domain:get-field-value($context, $updates)
   let $value := if($map-values) then $map-values else if($default-value) then $default-value else ()
   let $ns := domain:get-field-namespace($context)
   let $name := $context/@name
   return
     element {domain:get-field-qname($context)} {
      if($value instance of element()) then $value/node()
      else if($value instance of text()) then $value
      else if($partial and $current) then
        $current-value/node()
      else if($default-value) then attribute {(fn:QName($ns,$name))}{
        $default-value
      } else ()
    }
};

(:~
 : Creates a binary instance
:)
declare function model:build-binary(
   $context as node(),
   $current as node()?,
   $updates as item(),
   $partial as xs:boolean
) {
    let $type := fn:data($context/@type)
    let $key  := domain:get-field-id($context)
    let $current-value := domain:get-field-value($context,$current)
    let $default-value := fn:data($context/@default)
    let $ns := domain:get-field-namespace($context)
    let $localname := fn:data($context/@name)
    let $default   := (fn:data($context/@default),"")[1]
    let $occurrence := ($context/@occurrence,"?")
    let $map-values := domain:get-field-value($context, $updates)
    let $model := $context/ancestor::domain:model
    let $field-id := domain:get-field-id($context)
    let $fileType := ($context/@fileType,"auto")[1]
    let $binary := domain:get-param-value($updates,$field-id)
    let $binary := if($binary) then $binary else domain:get-param-value($updates,fn:data($context/@name))
    let $binaryFile :=
      if(fn:exists($binary)) then
          if($fileType eq "xml") then
              if ($binary instance of binary ()) then
                  xdmp:unquote(xdmp:binary-decode($binary,"utf-8"))
              else
                  xdmp:unquote($binary/node())
          else if($fileType eq "text") then
              xdmp:binary-decode($binary,"utf-8")
          else $binary
      else ()
    let $fileURI := $context/@fileURI
    let $fileURI :=
       if($fileURI and $fileURI ne "")
       then model:generate-uri($fileURI,$model,$updates)
       else
          let $binDirectory := $model/domain:binaryDirectory
          let $hasBinDirectory :=
               if($binDirectory or $fileURI) then ()
               else fn:error(xs:QName("MODEL-MISSING-BINARY-DIRECTORY"),"Model must configure field/@fileURI or model/binaryDirectory if binary/file fields are present",$field-id)
          return
               model:generate-uri($binDirectory,$model,$updates)
    let $filename :=
         if(domain:get-param-value($updates,fn:concat($field-id,"_filename")))
         then domain:get-param-value($updates,fn:concat($field-id,"_filename"))
         else domain:get-param-value($updates,fn:concat($context/@name,"_filename"))
    let $fileContentType :=
         if(domain:get-param-value($updates,fn:concat($field-id,"_content-type")))
         then domain:get-param-value($updates,fn:concat($field-id,"_content-type"))
         else domain:get-param-value($updates,fn:concat($context/@name,"_content-type"))
    return
         if(fn:exists($binary)) then (
             element {fn:QName($ns,$localname)} {
                attribute type {"binary"},
                attribute content-type {$fileContentType},
                attribute filename {$filename},
                attribute filesize {
                 if($binaryFile instance of binary())
                 then xdmp:binary-size($binaryFile)
                 else fn:string-length(xdmp:quote($binaryFile))
                },
                text {$fileURI}
             },
             if($fileURI ne $current/text())
             then  xdmp:document-delete($current/text())
             else  (),
            (:Binary Dependencies will get replaced automatically:)
             map:put($binary-dependencies,$fileURI,$binaryFile)
         )
         else
             $current-value
};
(:~
 : Builds an instance of an object from a model
 :)
declare function model:build-instance(
   $context as node(),
   $current as node()?,
   $updates as item()?,
   $partial as xs:boolean
) {
  let $value-type := domain:get-value-type($updates)
  let $model := domain:get-model($context/@type)
  let $current-values := domain:get-field-value($context,$current)
  let $update-values := domain:get-field-value($context,$updates)
  let $occurrence := ($context/@occurrence,"?")
    (:For each value we need to find the matching node by its identity or position:)
    let $values :=
        for $value at $pos in $update-values
        let $id-field    := domain:get-model-identity-field($model)
        let $id-value := domain:get-field-value($id-field,$value)
        let $current-by-id  := $current-values[cts:contains(.,domain:get-model-identity-query($model,$id-value))]
        let $current-by-pos := $current-values[$pos]
        let $matched :=
            if($current-by-id) then $current-by-id else if($partial and $current-by-pos) then $current-by-pos else ()
        return
          element { domain:get-field-qname($context) } {
            model:recursive-build($model,$matched,$value,$partial)/(@*|element())
          }
   return
     if($values) then
        if($occurrence = ("?","*"))
        then $values
        else ()
     else if(fn:exists($current-values) and $partial) then $current-values
     else ()
};
declare function model:build-langString(
    $context as node(),
    $current as node()?,
    $updates as item()*,
    $partial as xs:boolean
 ) {
   if(fn:exists($updates)) then
     for $value in  domain:get-field-value($context,$updates)
     let $lang := (sem:lang($value),$context/@defaultLanguage,"en")[1]
     return
        element {domain:get-field-qname($context)} {
          attribute xml:lang {$lang},
               fn:data($value)
        }
    else if($partial and fn:exists($current)) then
        $current
      else if($context/@default) then
         element {domain:get-field-qname($context)} {
            attribute xml:lang {($context/@defaultLanguage,"en")},
            fn:string($context/@default)
         }
      else ()
 };
(:~
 : Creates a triple based on an IRI Pattern
 :)
declare function model:build-triple(
   $context as node(),
   $current as node()?,
   $updates as item()*,
   $partial as xs:boolean
) {
    let $values := domain:get-field-value($context,$updates)
    let $subject-def   := ($values/*:subject, $context/@subject)[1]
    let $predicate-def := $context/@predicate
    let $object-def := $context/@object
    let $graph-def  := $context/@graph
    let $subject   :=  "http://marklogic.com/mdm/$(uuid)"
    let $predicate  := "foaf:knows"
    let $object     := "http://marklogic.com/mdm/$(country/@refId)"
    let $graph      := "dc:graph"
    return
      if($context/@occurrence = "+","*")
      then
       for $value in $values
       return
           element {domain:get-field-qname($context)} {
                xdmp:function(xs:QName("sem:triple"))(
                   model:generate-iri($subject,   $context/ancestor-or-self::domain:model,$updates),
                   model:generate-iri($predicate, $context/ancestor-or-self::domain:model,$updates),
                   model:generate-iri($object,    $context/ancestor-or-self::domain:model,$updates),
                   model:generate-iri($graph,     $context/ancestor-or-self::domain:model,$updates)
                )
            }
      else
       element {domain:get-field-qname($context)} {
          xdmp:function(xs:QName("sem:triple"))(
               model:generate-iri($subject,   $context/ancestor-or-self::domain:model,$updates),
               model:generate-iri($predicate, $context/ancestor-or-self::domain:model,$updates),
               model:generate-iri($object,    $context/ancestor-or-self::domain:model,$updates),
               model:generate-iri($graph,     $context/ancestor-or-self::domain:model,$updates)
          )
       }
};
(:~
 : Deletes the model document
 : @param $model the model of the document and any external binary files
 : @param $params the values to fill into the element
 : @return xs:boolean denoted whether delete occurred
~:)
declare function model:delete(
  $model as element(domain:model),
  $params as item()
) (:as xs:boolean?:) {
  let $cascade-delete := domain:get-param-value($params, "_cascade")
  let $params := domain:fire-before-event($model,"delete",$params)
  let $current := model:get($model,$params)
  let $current-identity-value := domain:get-field-value(domain:get-model-identity-field($model), $current)
  let $is-current := if($current) then () else fn:error(xs:QName("DELETE-ERROR"),"Could not find a matching document")
  let $is-referenced := domain:is-model-referenced($model,$current)
  return
    try {
      let $_ := if($is-referenced) then
        if (fn:exists($cascade-delete)) then
          for $item in cts:search(fn:collection(), domain:get-models-reference-query($model, $current))
          return (
            let $parent-instance := $item/node()
            (:let $parent-model := domain:get-domain-model($parent-instance/fn:local-name()):)
            let $parent-model := domain:get-domain-model(fn:string($parent-instance/@xsi:type))
            return
            if ($cascade-delete eq "remove") then
            (
              let $identity-field := domain:get-model-identity-field($parent-model)
              let $_ := xdmp:log(text{"About to delete", xdmp:node-uri($item)}, "debug")
              return model:delete(
                $parent-model,
                map:new((
                  map:entry($identity-field/@name, domain:get-field-value($identity-field, $parent-instance)),
                  map:entry("_cascade", "remove")
                ))
              )
            )
            else if ($cascade-delete eq "detach") then
            (
              let $_ := xdmp:log(text{"About to detach", xdmp:node-uri($item)}, "debug")
              let $parent-instance := model:convert-to-map($parent-model, $parent-instance)
              let $_ := $parent-model//domain:element[@reference = domain:get-model-reference-key($model)] ! (
                let $reference-field := .
                let $reference-value := domain:get-field-value($reference-field, $parent-instance)
                return map:put(
                  $parent-instance,
                  $reference-field/@name,
                  fn:remove($reference-value, fn:index-of($reference-value, $reference-value[@ref-id eq $current-identity-value]))
                )
              )
              return model:update($parent-model, $parent-instance)
            )
            else
            (xdmp:log(text{"Delete cascade option", $cascade-delete, "not supported"}, "info"))
          )
        else
          fn:error(
            xs:QName("REFERENCE-CONSTRAINT-ERROR"),
           "You are attempting to delete document which is referenced by other documents",
           domain:get-model-reference-uris($model,$current)
          )
      else
        ()
      return (
        xdmp:node-delete($current),
        model:delete-binary-dependencies($model,$current),
        let $event := domain:fire-after-event($model,"delete",$current)
        return (:fn:true():)
          if($event) then $event else fn:true()
      )
    } catch($ex) {
      xdmp:rethrow()
    }
};

(:~
 : Deletes any binaries defined by instance
 :)
declare function model:delete-binary-dependencies(
    $model as element(domain:model),
    $current as element()
) as empty-sequence() {
   let $binary-fields := $model//domain:element[@type = ("binary","file")]
   for $field in $binary-fields
   let $value := domain:get-field-value($field,$current)
   return
      if(fn:normalize-space($value) ne "" and fn:not(fn:empty($value)))
      then
      if(fn:doc-available($value)) then
        xdmp:document-delete($value)
      else (
         xdmp:log(fn:concat("DELETE-FILE-MISSING::field=",$field/@name," value=",$value))
      )
      else ()(:Binary not set so dont do anything:)
};

(:~
 :  Returns the lookup
 :)
declare function model:lookup(
  $model as element(domain:model),
  $params as item()
) as element(lookups)? {
  let $key := fn:data($model/@key)
  let $label := fn:data($model/@keyLabel)
  let $name := fn:data($model/@name)
  let $nameSpace :=  domain:get-field-namespace($model)
  let $qString := domain:get-param-value($params,"q")
  let $limit := model:page-size($model, $params, "ps")
  let $keyField := domain:get-model-key-field($model)
  let $keyLabel := domain:get-model-keyLabel-field($model)
  let $debug := domain:get-param-value($params,"debug")
  let $additional-constraint := domain:get-param-value($params,"_query")
  let $query :=
    cts:and-query((
      cts:element-query(
        fn:QName($nameSpace,$name),
        if($qString ne "") then
          cts:word-query(fn:concat("*",$qString,"*"),("diacritic-insensitive", "wildcarded","case-insensitive","punctuation-insensitive"))
        else
          cts:and-query(())
      ),
      domain:get-base-query($model),
      $additional-constraint
    ))
  let $values :=
    if($model/@persistence = 'document') then
      let $loc :=  $model/domain:document
      let $rootNode :=fn:data($loc/@root)
      let $xpath :=
        if($nameSpace) then
          fn:concat("/*:", $rootNode, "[fn:namespace-uri(.) = '", $nameSpace, "']/*:", $name, "[fn:namespace-uri(.) = '", $nameSpace, "']")
        else
          fn:concat("/", $rootNode, "/", $name)
      let $stmt :=  fn:string(<stmt>{fn:concat('fn:doc("', $loc/text() , '")', $xpath)}</stmt>)
      let $nodes := xdmp:value($stmt)
      let $lookup-values :=
        for $node in $nodes[cts:contains(.,$query)]
        let $key   := $node/(@*|*)[fn:local-name(.) = $key]/text()
        let $value := $node/(@*|*)[fn:local-name(.) = $label]/text()
        order by $value,$key
        return
          <lookup>
            <key>{$key}</key>
            <label>{$value}</label>
          </lookup>
      return
        if($limit) then
          $lookup-values[1 to $limit]
        else
          $lookup-values
    else if ($model/@persistence = 'directory') then
      let $keyFieldRef :=
        if($keyField instance of element(domain:attribute)) then
          cts:element-attribute-reference(fn:QName($nameSpace,$model/@name),fn:QName("",$keyField/@name))
        else
          cts:element-reference(fn:QName($nameSpace,$keyField/@name))
      let $keyLabelRef :=
        if($keyLabel instance of element(domain:attribute)) then
          cts:element-attribute-reference(fn:QName($nameSpace,$model/@name),fn:QName("",$keyLabel/@name))
        else
          cts:element-reference(fn:QName($nameSpace,$keyLabel/@name))
      for $item in
        cts:value-co-occurrences(
          $keyLabelRef,
          $keyFieldRef,
          ("item-order",if($limit) then fn:concat('limit=',$limit) else ()),
          $query
        )
      return
        <lookup>
          <key>{fn:data($item/cts:value[2])}</key>
          <label>{fn:data($item/cts:value[1])}</label>
        </lookup>
    else ()
    return
      <lookups type="{$name}">
        {if($debug) then $query else ()}
        {$values}
      </lookups>
};

(:~Recursively Removes elements based on @listable = true :)
declare function model:filter-list-result(
  $field as element(),
  $result,
  $params as item()
) {
  if(domain:navigation($field)/@listable eq "false") then
    ()
  else
    typeswitch($field)
      case element(domain:model)
        return
          element {domain:get-field-qname($field)} {
             for $field in $field/(domain:attribute)
             return model:filter-list-result($field,$result,$params),
             for $field in $field/(domain:element|domain:container)
             return model:filter-list-result($field,$result,$params)
          }
      case element(domain:element)
        return
          let $value := domain:get-field-value-node($field,$result)
          let $fieldtype := domain:get-base-type($field)
          for $val in $value
          return
           switch($fieldtype)
             case "complex" return $val
             default return
              element {domain:get-field-qname($field)} {
                for $field in $field/domain:attribute
                return model:filter-list-result($field,$val,$params),
                if($val instance of node()) then $val/node()
                else $val
              }
      case element(domain:container)
        return
          element {domain:get-field-qname($field)} {
            for $field in $field/domain:attribute
            return model:filter-list-result($field,$result,$params),
            for $field in $field/(domain:element|domain:container)
            return model:filter-list-result($field,$result,$params)
          }
      case element(domain:attribute)
        return
          attribute {domain:get-field-qname($field)} {
            domain:get-field-value($field,$result,fn:true())
          }
      default return ()
};

(:~
: Returns a list of packageType
: @return  element(packageType)*
:)
declare function model:list(
  $model as element(domain:model),
  $params as item()
) as element(list)? {
  let $listable := fn:not(domain:navigation($model)/@listable eq "false")
  return
  if(fn:not($listable))
  then fn:error(xs:QName("MODEL-NOT-LISTABLE"),fn:concat($model/@name, " is not listable"))
  else
    let $name := $model/@name
    let $search := model:list-params($model,$params)
    let $persistence := $model/@persistence
    let $namespace := domain:get-field-namespace($model)
    let $model-prefix := domain:get-field-prefix($model)
    let $model-qname := fn:concat("/",$model-prefix,":",$model/@name)
    let $predicateExpr := ()
    let $listExpr :=
      for $field in $model//(domain:element|domain:attribute)[@name = domain:get-param-keys($params)]
      return
        domain:get-field-query($field,domain:get-field-value($field,$params))
    let $additional-query := model:build-search-query($model, $params, "cts:query")
    let $list  :=
      if ($persistence = 'document') then
        let $path := $model/domain:document/fn:string()
        let $root := fn:data($model/domain:document/@root)
        return
          "fn:doc('" || $path || "')/"|| $model-prefix ||":" || $root || $model-qname ||  "[cts:contains(.,cts:and-query(($search,$additional-query)))]"
      else
        let $dir := cts:directory-query($model/domain:directory/text())
        let $predicate :=
          cts:element-query(fn:QName($namespace,$name),
            cts:and-query((
              domain:model-root-query($model),
              (:domain:get-base-query($model),:)
              $additional-query,
              $search,
              $dir,
              $listExpr
            ))
          )
        let $_ := xdmp:set($predicateExpr,($predicateExpr,$predicate))
        return
        (
          fn:concat("cts:search(fn:collection(),", $predicate, ")")
        )
    let $total :=
      if($persistence = 'document')
      then xdmp:with-namespaces(domain:declared-namespaces($model), xdmp:value(fn:concat("fn:count(", $list, ")")))
      else xdmp:estimate(cts:search(
        fn:collection(),
        cts:element-query(fn:QName($namespace,$name),cts:and-query(($search,$predicateExpr)))
      ))

    let $sorting := model:sorting($model, $params, ("sort", "sort.name", "sidx"), ("", "sort.order", "sord"))
    let $sort :=
      fn:string-join(
        (
        for $field in $sorting/field
        let $domain-sort-field := $model//(domain:element|domain:attribute)[(domain:get-field-name-key(.),@name) = ($field/@name)][1]
        let $domain-sort-as :=
          if(fn:exists($domain-sort-field)) then
            fn:concat("[1] cast as ", domain:resolve-datatype($domain-sort-field), "?")
          else
            ()
        return
          if(fn:exists($domain-sort-field)) then
            let $collation-sort-field := fn:concat(" collation '", domain:get-field-collation($domain-sort-field), "' ")
            let $sortPath :=
              if($persistence = 'document') then
                fn:substring-after(domain:get-field-absolute-xpath($domain-sort-field), $model-qname)
              else
                domain:get-field-absolute-xpath($domain-sort-field)
            return
              if($field/@order = ("desc","descending")) then
                fn:concat("($__context__",$sortPath,")",$domain-sort-as," descending", $collation-sort-field)
              else
                fn:concat("($__context__",$sortPath,")",$domain-sort-as," ascending", $collation-sort-field)
          else ()
        ),
        ","
      )
    (: 'start' is 1-based offset in records from 'page' which is 1-based offset in pages
     : which is defined by 'rows'. Perfectly fine to give just start and rows :)
    let $pageSize := model:page-size($model, $params, "rows")
    let $page     := xs:integer((domain:get-param-value($params, 'page'),1)[1])
    let $start   := xs:integer((domain:get-param-value($params, 'start'),1)[1])
    let $start    := $start + ($page - 1) * $pageSize
    let $last     :=  $start + $pageSize - 1
    let $end      := if ($total > $last) then $last else $total
    let $all := xs:boolean(domain:get-param-value($params,"all"))
    let $resultsExpr :=
      if($all) then
        if($sort ne "" and fn:exists($sort))
        then fn:concat("(for $__context__ in ", $list, " order by ",$sort, " return $__context__)")
        else $list
      else
        if($sort ne "" and fn:exists($sort))
        then fn:concat("(for $__context__ in ", $list, " order by ",$sort, " return $__context__)[",$start, " to ",$end,"]")
        else fn:concat("(", $list, ")[$start to $end]")
    let $results := xdmp:with-namespaces(domain:declared-namespaces($model), xdmp:value($resultsExpr))
    let $results :=
      if($persistence = "directory")
      then
        for $result in $results
        return
         model:filter-list-result($model,$result/node(),$params)
      else $results
    return
      <list type="{$name}" elapsed="{xdmp:elapsed-time()}">
        { attribute xmlns { domain:get-field-namespace($model) } }
        { $sorting }
        <currentpage>{$page}</currentpage>
        <pagesize>{$pageSize}</pagesize>
        <totalpages>{fn:ceiling($total div $pageSize)}</totalpages>
        <totalrecords>{$total}</totalrecords>
        {(:Add Additional Debug Arguments:)
          if(xs:boolean(domain:get-param-value($params,"debug"))) then (
            <debugQuery>{xdmp:describe($predicateExpr,(),())}</debugQuery>,
            <searchString>{$search}</searchString>,
            <sortString>{$sort}</sortString>,
            <expr>{$resultsExpr}</expr>,
            <params>{$params}</params>
          ) else ()
        }
        {$results}
      </list>
};

(:~
 : Converts Search Parameters to cts search construct for list;
 :)
declare function model:list-params(
    $model as element(domain:model),
    $params as item()
) {
      let $sf := domain:get-param-value($params,"searchField"),
          $so := domain:get-param-value($params,"searchOper"),
          $sv := domain:get-param-value($params,"searchString"),
          $filters := domain:get-param-value($params,"filters")[1]
      return
        if(fn:exists($sf) and fn:exists($so) and fn:exists($sv) and
           $sf ne "" and $so ne "")
        then
            let $op := $so
            let $field-elem := domain:get-model-field($model, $sf)
            let $field := fn:QName(domain:get-field-namespace($field-elem),$field-elem/@name)
            let $value := domain:get-param-value($params,"searchString")[1]
            return
                operator-to-cts($field-elem,$op,$value)
       else if(fn:exists($filters[. ne ""])) then
            let $parsed  := <x>{xdmp:from-json($filters)}</x>/*
            let $groupOp := ($parsed/json:entry[@key eq "groupOp"]/json:value,"AND")[1]
            let $rules :=
                for $rule in $parsed//json:entry[@key eq "rules"]/json:value/json:array/json:value/json:object
                let $op :=  $rule/json:entry[@key='op']/json:value
                let $sf :=  $rule/json:entry[@key='field']/json:value
                let $sv :=  $rule/json:entry[@key='data']/json:value
                let $field-elem := domain:get-model-field($model, $sf)
                let $field :=
                    fn:QName(domain:get-field-namespace($field-elem),$field-elem/@name)
                return
                  if($op and $sf and $sv) then
                  operator-to-cts($field-elem,$op, $sv)
                  else ()
            return
               if($groupOp eq "OR") then
                   cts:or-query((
                      $rules
                   ))
               else cts:and-query((
                 $rules
               ))
            else  ()
};

declare function model:page-size(
  $model as element(domain:model),
  $params,
  $param-name as xs:string?
) as xs:unsignedLong? {
  let $param-name :=
    if (fn:exists($param-name)) then
      $param-name
    else
      "ps"
  return xs:unsignedLong((domain:get-param-value($params, $param-name), domain:navigation($model)/@pageSize, $DEFAULT-PAGE-SIZE)[1])
};

declare function model:sort-field(
  $model as element(domain:model),
  $params,
  $param-name as xs:string?
) as xs:string? {
  let $param-name :=
    if (fn:exists($param-name)) then
      $param-name
    else
      "sidx"
  let $sort-field := domain:get-param-value($params, $param-name)[1][. ne ""]
  let $model-sort-field := domain:navigation($model)/@sortField
  return ($sort-field, $model-sort-field)[1]
};

declare function model:sort-order(
  $model as element(domain:model),
  $params,
  $param-name as xs:string?
) as xs:string? {
  let $param-name :=
    if (fn:exists($param-name)) then
      $param-name
    else
      "sord"
  let $sort-order := domain:get-param-value($params,"sord")[1]
  let $model-order := (domain:navigation($model)/@sortOrder, "ascending")[1]
  return ($sort-order, $model-order)[1]
};

(: sorting function support dotted notation for $field-param-name and $order-param-name :)
declare function model:sorting(
  $model as element(domain:model),
  $params,
  $field-param-name as xs:string*,
  $order-param-name as xs:string*
) as element(sort)? {
  let $validate-order := function ($order) {
    if ($order = ("ascending", "descending")) then
      $order
    else if ($order = ("-", "desc")) then
      "descending"
    else if ($order = ("+", "asc")) then
      "ascending"
    else
      ()
  }
  let $field-param-names :=
    if (fn:exists($field-param-name)) then
      $field-param-name
    else
      "sidx"
  let $order-param-names :=
    if (fn:exists($order-param-name)) then
      $order-param-name
    else
      "sord"
  let $sort-fields :=
    for $field-param-name at $index in $field-param-names
    let $order-param-name := $order-param-names[$index]
    let $field-values :=
      if (fn:contains($field-param-name, '.') and fn:contains($order-param-name, '.')) then
        let $field-names := fn:tokenize($field-param-name, '\.')
        let $order-names := fn:tokenize($order-param-name, '\.')
        return
        switch(domain:get-value-type($params[1]))
          case "xml"
          return
            let $field := xdmp:value(fn:concat("$params/*:", $field-names[1]))
            let $order := xdmp:value(fn:concat("$params/*:", $order-names[1]))
            return
              for $value at $index in $field
              let $value := domain:get-param-value($value, $field-names[2])
              let $order := domain:get-param-value($order[$index], $order-names[2])
              return
                element field {
                  attribute name {$value},
                  attribute order {$validate-order($order)}
                }
          default
          return
            let $field := domain:get-param-value($params, $field-names[1])
            let $order := domain:get-param-value($params, $order-names[1])
            return
              for $value at $index in $field
              let $value := domain:get-param-value($value, $field-names[2])
              let $order := domain:get-param-value($order[$index], $order-names[2])
              return
                element field {
                  attribute name {$value},
                  attribute order {$validate-order($order)}
                }
      (: Add support for shorter notation: +field1,-field2 :)
      else if ($order-param-name eq "") then
        let $field := domain:get-param-value($params, $field-param-name)
        return
          if ($field castable as xs:string) then
            let $field := fn:tokenize(domain:get-param-value($params, $field-param-name), ',')
            return
              for $value at $index in $field
              let $order := fn:substring($value, 1, 1)
              let $value := fn:substring($value, 2)
              return
                element field {
                  attribute name {$value},
                  attribute order {$validate-order($order)}
                }
          else
            ()
      else
        let $field := domain:get-param-value($params, $field-param-name)
        let $order := domain:get-param-value($params, $order-param-name)
        return
          for $value at $index in $field
          return
            element field {
              attribute name {$value},
              attribute order {$validate-order($order[$index])}
            }
    return
      if (fn:exists($field-values)) then
        element sort {
          $field-values
        }
      else
        ()

  let $sort-fields := $sort-fields[1]
  return
    if (fn:exists($sort-fields)) then
      $sort-fields
    else
      let $field := fn:tokenize(domain:navigation($model)/@sortField, ',')
      let $order := fn:tokenize(domain:navigation($model)/@sortOrder, ',')
      let $field-values :=
        for $value at $index in $field
        return
          element field {
            attribute name {$value},
            attribute order {$validate-order($order[$index])}
          }
  return
    if (fn:exists($field-values)) then
      element sort {
      $field-values
    }
    else
      ()
};

(:~
 : Converts a list operator to its cts:* equivalent
 :)
declare private function model:operator-to-cts(
  $field as element(),
  $op as xs:string,
  $value as item()?
) {
  model:operator-to-cts($field,$op,$value,fn:false())
};

(:~
 : Converts a list operator to its cts:equivalent
 :)
declare private function model:operator-to-cts(
  $field-elem as element(),
  $op as xs:string,
  $value as item()?,
  $ranged as xs:boolean
) {
  let $ancestor-element := ($field-elem/ancestor::domain:element,$field-elem/ancestor::domain:model)[1]
  let $ancestor-qname := domain:get-field-qname($ancestor-element)
  let $field := domain:get-field-qname($field-elem)
  return
    if($field-elem/@type eq "reference") then
      let $ref := fn:QName("","ref-id")
      return
        if($op eq "eq") then
          if($ranged) then
            cts:or-query((
              cts:element-attribute-range-query($field,$ref,"=",$value),
              cts:element-value-query($field,$value)
            ))
          else
            cts:or-query((
              cts:element-attribute-value-query($field,$ref,$value),
              cts:element-value-query($field,$value)
            ))
        else if($op eq "ne") then
          if($ranged) then
            cts:and-query((
              cts:element-attribute-range-query($field,$ref,"!=",$value),
              cts:element-range-query($field,"!=", $value)
            ))
          else
            cts:and-query((
              cts:not-query( cts:element-attribute-value-query($field,$ref,$value)),
              cts:not-query(cts:element-value-query($field,$value))
            ))
        else if($op eq "bw") then
          cts:or-query((
            cts:element-attribute-word-query($field,$ref,fn:concat($value,"*"),("wildcarded")),
            cts:element-value-query($field,$value,fn:concat($value,"*"),("wildcarded"))
          ))
        else if($op eq "bn") then
          cts:and-query((
            cts:not-query( cts:element-attribute-value-query($field,$ref,fn:concat($value,"*")),("wildcarded")),
            cts:not-query(cts:element-value-query($field,$value,fn:concat($value,"*")),("wildcarded"))
          ))
        else if($op eq "ew") then
          cts:and-query((
            cts:element-attribute-value-query($field,$ref,fn:concat("*",$value),("wildcarded")),
            cts:element-value-query($field,$value,fn:concat("*",$value),("wildcarded"))
          ))
        else if($op eq "en") then
          cts:and-query((
            cts:not-query(cts:element-attribute-value-query($field,$ref,fn:concat("*",$value),("wildcarded"))),
            cts:not-query(cts:element-value-query($field,fn:concat($value,"*")),("wildcarded"))
          ))
        else if($op eq "cn") then
          cts:or-query((
            cts:element-attribute-word-query($field,$ref,fn:concat("*",$value,"*"),("wildcarded")),
            cts:element-word-query($field,fn:concat("*",$value,"*"),("wildcarded","case-insensitive"))
          ))
        else if($op eq "nc") then
          cts:and-query((
            cts:not-query(cts:element-attribute-value-query($field,$ref,fn:concat("*",$value,"*"))),
            cts:not-query(cts:element-value-query($field,fn:concat("*",$value,"*")))
          ))
        else if($op eq "nu") then
          cts:or-query((
            cts:element-attribute-value-query($field,$ref,cts:and-query(())),
            cts:element-query($field,cts:and-query(()))
          ))
        else
          ()
    else
      if($op eq "eq") then
        if($ranged) then
          cts:element-range-query($field,"=",$value)
        else
          cts:or-query((
            cts:element-attribute-value-query($ancestor-qname,$field,$value,"case-insensitive"),
            cts:element-value-query($field,$value,"case-insensitive")
          ))
      else if($op eq "ne") then
        if($ranged) then
          cts:element-range-query($field,"!=",$value)
        else
          cts:and-query((
            cts:not-query(cts:element-attribute-value-query($ancestor-qname,$field,$value)),
            cts:not-query(cts:element-value-query($field,$value))
          ))
      else if($op eq "bw") then
        cts:or-query((
          cts:element-attribute-value-query($ancestor-qname,$field,fn:concat($value,"*"),("wildcarded")),
          cts:element-value-query($field,fn:concat($value,"*"),("wildcarded"))
        ))
      else if($op eq "bn") then
        (:cts:not-query( cts:element-value-query($field,fn:concat($value,"*"),("wildcarded"))):)
        cts:and-query((
          cts:not-query(cts:element-attribute-value-query($ancestor-qname,$field,fn:concat($value,"*")),("wildcarded")),
          cts:not-query(cts:element-value-query($field,$value,fn:concat($value,"*")),("wildcarded"))
        ))
      else if($op eq "ew") then
        (:cts:element-value-query($field,fn:concat("*",$value)):)
        cts:or-query((
          cts:element-attribute-value-query($ancestor-qname,$field,fn:concat("*",$value),("wildcarded")),
          cts:element-value-query($field,$value,fn:concat("*",$value),("wildcarded"))
        ))
      else if($op eq "en") then
        (:cts:not-query( cts:element-value-query($field,fn:concat("*",$value),("wildcarded"))):)
        cts:and-query((
          cts:not-query(cts:element-attribute-value-query($ancestor-qname,$field,fn:concat("*",$value),("wildcarded"))),
          cts:not-query(cts:element-value-query($field,fn:concat("*",$value),("wildcarded")))
        ))
      else if($op eq "cn") then
        (:cts:element-word-query($field,fn:concat("*",$value,"*"),("wildcarded")):)
        cts:or-query((
          cts:element-attribute-word-query($ancestor-qname,$field,fn:concat("*",$value,"*"),("wildcarded")),
          cts:element-word-query($field,fn:concat("*",$value,"*"),("wildcarded","case-insensitive"))
        ))
      else if($op eq "nc") then
        (:cts:not-query( cts:element-word-query($field,fn:concat("*",$value,"*"),("wildcarded"))):)
        cts:and-query((
          cts:not-query(cts:element-attribute-word-query($ancestor-qname,$field,fn:concat("*",$value,"*"),("wildcarded"))),
          cts:not-query(cts:element-word-query($field,fn:concat("*",$value,"*"),("wildcarded")))
        ))
      else if($op eq "nu") then
        (:cts:element-query($field,cts:and-query(())):)
        cts:or-query((
          cts:element-attribute-value-query($ancestor-qname,$field,cts:and-query(())),
          cts:element-query($field,cts:and-query(()))
        ))
      else if($op eq "nn") then
        (:cts:element-query($field,cts:or-query(())):)
        cts:or-query((
          cts:element-attribute-value-query($ancestor-qname,$field,cts:or-query(())),
          cts:element-query($field,cts:or-query(()))
        ))
      else if($op eq "in") then
        (:cts:element-value-query($field,$value):)
        cts:or-query((
          cts:element-attribute-value-query($ancestor-qname,$field,$value),
          cts:element-value-query($field,$value)
        ))
      else if($op  eq "ni") then
        (:cts:not-query( cts:element-value-query($field,$value)):)
        cts:and-query((
          cts:not-query(cts:element-attribute-value-query($ancestor-qname,$field,$value)),
          cts:not-query( cts:element-value-query($field,$value))
        ))
      else
        ()
};

declare function model:build-search-options(
  $model as element(domain:model)
)  as element(search:options)
{
   model:build-search-options($model,map:map())
};

(:~
 : Build search options for a given domain model
 : @param $model the model of the content type
 : @return search options for the given model
 :)
declare function model:build-search-options(
  $model as element(domain:model),
  $params as item()
) as element(search:options) {
  let $properties := $model//(domain:element|domain:attribute)[domain:navigation/@searchable = ('true')]
  let $modelNamespace :=  domain:get-field-namespace($model)
  let $baseOptions :=
      if(fn:exists(domain:get-param-value($params, "search:options"))) then
        domain:get-param-value($params, "search:options")
      else if(fn:exists($model/search:options)) then
        $model/search:options
      else
        ()
  let $nav := domain:navigation($model)
  let $constraints := model:build-search-constraints($model, $params)
  let $suggestOptions :=
    for $prop in $properties[domain:navigation/@suggestable = "true"]
    let $prop-nav := domain:navigation($prop)
    let $type := ($prop-nav/@searchType,"value")[1]
    let $collation := domain:get-field-collation($prop)
    let $facet-options := $prop-nav/search:facet-option
    let $ns := domain:get-field-namespace($prop)
    return
      <search:suggestion-source ref="{$prop/@name}">{
        element { fn:QName("http://marklogic.com/appservices/search","range") } {
          attribute collation {$collation},
          if ($type eq 'range')
          then attribute type { "xs:string" }
          else (),
          <search:element name="{$prop/@name}" ns="{$ns}" >{
          (
            if ($prop instance of attribute()) then
              <search:attribute name="{$prop/@name}" ns="{$ns}"/>
            else ()
          )
          }</search:element>,
          $facet-options
        }
      }</search:suggestion-source>
  let $sortOptions :=
    for $prop in $properties[domain:navigation/@sortable = "true"]
      let $collation := domain:get-field-collation($prop)
      let $search-element := model:build-search-element($prop)
      return (
        <search:state name="{model:search-sort-state($prop, "ascending")}">
          <search:sort-order direction="ascending" type="{$prop/@type}" collation="{$collation}">
            {$search-element}
          </search:sort-order>
          <search:sort-order>
            <search:score/>
          </search:sort-order>
        </search:state>,
        <search:state name="{model:search-sort-state($prop, "descending")}">
          <search:sort-order direction="descending" type="{$prop/@type}" collation="{$collation}">
            {$search-element}
          </search:sort-order>
          <search:sort-order>
            <search:score/>
          </search:sort-order>
        </search:state>
      )

  let $extractMetadataOptions :=
     for $prop in $properties[domain:navigation/@metadata = "true"]
     let $ns := domain:get-field-namespace($prop)
     return
      if ($prop instance of element(domain:attribute)) then
        let $parent := domain:get-parent-field-attribute($prop)
        let $parent-ns := domain:get-field-namespace($parent)
        return <search:qname elem-ns="{$parent-ns}" elem-name="{$parent/@name}" attr-ns="{$ns}" attr-name="{$prop/@name}"/>
      else
        <search:qname elem-ns="{$ns}" elem-name="{$prop/@name}"></search:qname>

  (:Implement a base query:)
  let $persistence := fn:data($model/@persistence)
  let $baseQuery :=
    if ($persistence = ("document","singleton")) then
      cts:document-query($model/domain:document/text())
    else if($persistence = "directory") then
      cts:directory-query($model/domain:directory/text())
    else ()

  let $addQuery := cts:and-query((
    $baseQuery,
    domain:get-param-value($params,"_query")
    (:Need to allow to pass additional query through params:)
  ))

  let $options :=
    <search:options>
      <search:return-query>{fn:true()}</search:return-query>
      <search:return-facets>{fn:true()}</search:return-facets>
      <search:additional-query>{$addQuery}</search:additional-query>
      <search:suggestion-source>{
          $model/search:options/search:suggestion-source/(@*|node())
      }</search:suggestion-source>

      {$constraints,
       $suggestOptions,
       $model/search:options/search:constraint
      }
      <search:operator name="sort">{
         $sortOptions,
         $model/search:options/search:operator[@name = "sort"]/*
      }</search:operator>
      {$baseOptions/search:operator[@name ne "sort"]}
      {$baseOptions/*[. except $baseOptions/(search:constraint|search:operator|search:suggestion-source)]}
      <search:extract-metadata>{$extractMetadataOptions}</search:extract-metadata>
    </search:options>
  return $options
};

declare function model:build-search-constraints(
  $model as element(domain:model),
  $params as item()
) {
  let $properties := $model//(domain:element|domain:attribute)[fn:not(domain:navigation/@searchable = ('false') and domain:navigation/@facetable = ('false'))]
  return
    for $prop in $properties (:[domain:navigation/@searchable = "true"]:)
      for $prop-nav in $prop/domain:navigation
      let $name := if($prop-nav/@constraintName) then $prop-nav/@constraintName else $prop/@name
      let $type := (
        $prop-nav/@searchType,
        if($prop-nav/(@suggestable|@facetable) = "true") then
          "range"
        else
          "value"
      )[1]
      let $facet-options := $prop-nav/search:facet-option
      let $term-options := $prop-nav/(search:term-option|search:weight)
      let $term-options := if($term-options) then $term-options else domain:get-param-value($params, "search:term-options")
      return
        <search:constraint name="{$name}" label="{$prop/@label}">{
          element { fn:QName("http://marklogic.com/appservices/search",$type) } {
            attribute collation {domain:get-field-collation($prop)},
            if ($type eq 'range') then
              attribute type { domain:resolve-ctstype($prop) }
            else
              attribute type {"xs:string"}
            ,
            if ($prop-nav/@facetable eq 'true') then
              attribute facet { fn:true() }
            else
              attribute facet { fn:false() }
            ,
            model:build-search-element($prop),
            $term-options,
            $facet-options
          }
        }</search:constraint>
};

declare %private function model:build-search-element(
  $field as element()
) as element()* {
  if ($field instance of element(domain:attribute)) then
    let $field-prop := domain:get-parent-field-attribute($field)
    return
    (
      <search:element ns="{domain:get-field-namespace($field-prop)}" name="{fn:data($field-prop/@name)}"/>,
      <search:attribute name="{$field/@name}"/>
    )
  else
    <search:element ns="{domain:get-field-namespace($field)}" name="{$field/@name}"/>
};

declare function model:search-sort-state(
  $field as element(),
  $order as xs:string?
) as xs:string {
  let $order :=
    if ($order eq "ascending" or $order eq "descending") then
      $order
    else
      "ascending"
  let $name :=
      typeswitch($field)
        case element(domain:attribute) return fn:concat($field/../@name,"_",$field/@name)
        case element(domain:element) return fn:data($field/@name)
        default return fn:error(xs:QName("FIELD-NOT-SUPPORTED"), text{"Field type not supported."}, $field)
  return fn:concat($name, "-", $order)
};

declare function model:build-search-query(
  $model as element(domain:model),
  $params as item()
) {
  model:build-search-query($model, $params, ())
};

declare function model:build-search-query(
  $model as element(domain:model),
  $params as item(),
  $output as xs:string?
) {
  let $output :=
    if (fn:empty($output)) then
      "cts:query"
    else if ($output eq "cts:query" or $output eq "search:query") then
      $output
    else
      fn:error(xs:QName("OUTPUT-NOT-SUPPORTED"), text{"Output parameter", $output, "not supported"})
  let $additional-query := domain:get-param-value($params,"_query")
  return
    if($additional-query castable as xs:string) then
      let $query := search:parse($additional-query, model:build-search-options($model, $params), $output)
      return
        if ($output eq "cts:query") then
          cts:query($query)
        else
          $query
    else
      $additional-query
};

(:~
 : Provide search interface for the model
 : @param $model the model of the content type
 : @param $params the values to fill into the search
 : @return search response element
 :)
declare function model:search($model as element(domain:model), $params as item())
as element(search:response)
{
   let $query as xs:string* := domain:get-param-value($params, "query")
   let $sort as xs:string?  := domain:get-param-value($params, "sort")
   let $page as xs:integer  := (domain:get-param-value($params, "pg"),1)[1] cast as xs:integer
   let $page-size as xs:integer? := model:page-size($model, $params, "ps")
   let $start := (($page - 1) * $page-size) + 1
   let $end := ($page * $page-size)
   let $final := fn:concat($query," ",$sort)
   let $options := model:build-search-options($model,$params)
   let $results :=
     search:search($final,$options,$start,$page-size)
   return
     <search:response>
     {attribute type {$model/@name}}
     {attribute page {$page}}
     {$results/(@*|node())}
     {$options}
     </search:response>
};

(:~
 : Provide search:suggest interface for the model
 : @param $model the model of the content type
 : @param $params the values to fill into the search
 : @return search response element
 :)
declare function model:suggest(
  $model as element(domain:model),
  $params as item()
) as xs:string* {
   let $options := model:build-search-options($model,$params)
   let $query := (domain:get-param-value($params,"query"),"")[1]
   (:let $limit := (domain:get-param-value($params,"limit"),10)[1] cast as xs:integer:)
   let $limit := model:page-size($model, $params, "limit")
   let $position := (domain:get-param-value($params,"position"),fn:string-length($query[1]))[1] cast as xs:integer
   let $focus := (domain:get-param-value($params,"focus"),1)[1] cast as xs:integer
   return
       search:suggest($query,$options,$limit,$position,$focus)
};

(:~
 :  returns a reference given an id or field value.
 :)
declare function model:get-references($field as element(), $params as item()*) {
    let $refTokens := fn:tokenize(fn:data($field/@reference), ":")
    let $element := $refTokens[1]
    return
        switch ($element)
        case "model"       return model:get-model-references($field,$params)
        case "application" return model:get-application-reference($field,$params)
        case "controller"  return model:get-controller-reference($field,$params)
        case "optionlist"  return model:get-optionlist-reference($field,$params)
        case "extension"   return model:get-extension-reference($field,$params)
        default return ()
};
declare function model:get-function-cache(
  $function as function(*)
) {
  let $func-hash := xdmp:hmac-md5("function",xdmp:describe($function,(),()))
  let $func := map:get($FUNCTION-CACHE,$func-hash)
  return
    if(fn:exists($func)) then $func
    else (
        map:put($FUNCTION-CACHE,$func-hash,$function),
        $function
    )
};

(:~
 : This function will call the appropriate reference type model to build
 : a relationship between two models types.
 : @param $reference is the reference element that is used to contain the references
 : @param $params the params items to build the relationship
 :)
 declare function model:get-model-references(
    $reference as element(domain:element),
    $params as item()*
 ) as element()* {
  let $name := fn:data($reference/@name)
  let $target := fn:data($reference/@reference)
  let $tokens := fn:tokenize($target, ":")
  let $type := $tokens[2]
  let $reference-function-name := $tokens[3]
  let $function-arity := 3
  let $funct := domain:get-model-function((), $type, $reference-function-name, $function-arity, fn:false())
  let $funct := model:get-function-cache($funct)
  return
    if (fn:exists($funct)) then
      let $model := domain:get-domain-model($type)
      for $param in $params
      return $funct($reference, $model, $param)
    else
      fn:error(xs:QName("ERROR"), "No Reference function '" || $target || "' available for field '" || $name || "'.")
 };

(:~
  : Returns a reference to a given controller
 ~:)
 declare function model:get-controller-reference($reference as element(domain:element), $params as item()) {
   ()
 };


 (:~
  : Returns a reference from an optionlist
 ~:)
 declare function model:get-optionlist-reference($reference as element(domain:element), $params as item()) {
   ()
 };
 (:~~:)
 declare function model:get-extension-reference($reference as element(domain:element),$params as item()) {
   ()
 };

declare function model:set-cache-reference($model as element(domain:model),$keys as xs:string*,$values as item()*) {
    $keys ! map:put($REFERENCE-CACHE,fn:concat(xdmp:hash64(xdmp:describe($model)),"::", .),$values)
};
declare function model:get-cache-reference($model as element(domain:model),$keys as xs:string) {
     $keys ! map:get($REFERENCE-CACHE,fn:concat(xdmp:hash64(xdmp:describe($model)),"::", .))
};

declare function model:reference(
  $context as element(),
  $model as element(domain:model),
  $params as item()*
) as element()? {
  let $keyLabel := fn:data($model/@keyLabel)
  let $key := fn:data($model/@key)
  let $modelReference :=
    typeswitch ($params)
      case element() return
        if (fn:string($params/@xsi:type) eq fn:string($model/@name)) then
          $params
        else
          model:get($model, $params/node())
      default return model:get($model, $params)
  let $name := fn:data($model/@name)
  return
    if($modelReference) then
      element {domain:get-field-qname($context)} {
         attribute ref-type { "model" },
         attribute ref-id   { domain:get-field-value(domain:get-model-identity-field($model), $modelReference) },
         attribute ref      { $name },
         domain:get-field-value(domain:get-model-keylabel-field($model), $modelReference)
      }
    else ()(: fn:error(xs:QName("INVALID-REFERENCE-ERROR"),"Invalid Reference", fn:data($model/@name)):)
};

(:~
 : This function will create a reference of an existing element
 : @node-name reference element attribute name
 : @param $ids a sequence of ids for models to be extracted
 : @return a sequence of packageType
 :)
declare function model:instance(
  $context as element(),
  $model as element(domain:model),
  $params as item()*
) {
  let $key := fn:data($model/@key)
  let $modelReference := model:get($model,$params)
  let $name := fn:data($model/@name)
  return
    if($modelReference) then
      element { domain:get-field-qname($model) } {
         attribute ref-type { "model" },
         (:attribute ref-uuid { $modelReference/(@*|*:uuid)/text() },:)
         attribute ref-id   { fn:data($modelReference/(@*|node())[fn:local-name(.) = $key])},
         attribute ref      { $name },
         $modelReference/node()
      }
    else ()(: fn:error(xs:QName("INVALID-REFERENCE-ERROR"),"Invalid Reference", fn:data($model/@name)):)
};

(:~
 :
 :)
declare  function model:get-application-reference($field,$params){
   let $reference := fn:data($field/@reference)
   let $ref-tokens := fn:tokenize($reference,":")
   let $ref-parent   := $ref-tokens[1]
   let $ref-type     := $ref-tokens[2]
   let $ref-action   := $ref-tokens[3]
   let $localName := fn:data($field/@name)
   let $ns := domain:get-field-namespace($field)
   let $qName := fn:QName($ns,$localName)
   return
      if($ref-parent eq "application" and $ref-type eq "model")
      then
        let $domains := xdmp:value(fn:concat("domain:model-",$ref-action))
        let $key := domain:get-field-id($field)
        return
            for $value in $params
            let $domain := $domains[@name = $value]
            return
                if($domain) then
                     element { $qName } {
                         attribute ref-type { "application" },
                         attribute ref-id { fn:data($domain/@name)},
                         attribute ref { $field/@name },
                         fn:data($domain/@label)
                     }
                else ()
      else if($ref-parent eq "application" and $ref-type eq "class")
      then  xdmp:apply(xdmp:function("model",$ref-action),$ref-type)
      else fn:error(xs:QName("REFERENCE-ERROR"),"Invalid Application Reference",$ref-action)
 };

 (:~
  : Returns the reference from an application
  :)
 declare  function model:get-application-reference-values($field){
   let $reference := fn:data($field/@reference)
   let $ref-tokens := fn:tokenize($reference,":")
   let $ref-parent   := $ref-tokens[1]
   let $ref-type     := $ref-tokens[2]
   let $ref-action   := $ref-tokens[3]
   let $localName := fn:data($field/@name)
   let $ns := domain:get-field-namespace($field)
   let $qName := fn:QName($ns,$localName)
   return
      if($ref-parent eq "application" and $ref-type eq "model")
      then
        let $domains := xdmp:value(fn:concat("domain:model-",$ref-action))
        return
           $domains
      else if($ref-parent eq "application" and $ref-type eq "class")
      then  xdmp:apply(xdmp:function("model",$ref-action),$ref-type)
      else fn:error(xs:QName("REFERENCE-ERROR"),"Invalid Application Reference",$ref-action)
 };

(:~
: This is a function that will validate the params with the domain model
: @param domain-model the model to validate against
: @param $params the params to validate
: @return return a set of validation errors if any occur.
 :)
declare function model:validate-params(
  $model as element(domain:model),
  $params as item()*,
  $mode as xs:string
) as empty-sequence() {
  if (fn:not(domain:model-validation-enabled($model))) then ()
  else
    let $validation-errors :=
    (
      let $custom-validators := domain:validators($model)
      return
        for $custom-validator in $custom-validators
        return
          let $function-name := fn:string($custom-validator/@function)
          let $validator-function := domain:get-model-function((), $model/@name, $function-name, 3, fn:false())
          return
            if (fn:exists($validator-function)) then
              $validator-function($model, $params, $mode)
            else
              (),

      let $unique-constraints := domain:get-model-unique-constraint-fields($model)
      let $unique-search := domain:get-model-unique-constraint-query($model,$params,$mode)
      return
        if($unique-search) then
          for $v in $unique-constraints
          let $param-value := domain:get-field-value($v,$params)
          let $param-value := if($param-value) then $param-value else $v/@default
          return
          <validationError>
            <element>{fn:data($v/@name)}</element>
            <type>unique</type>
            <error>Instance is not unique.Field:{fn:data($v/@name)} Value: {$param-value}</error>
          </validationError>
        else (),
      let $uniqueKey-constraints := domain:get-model-uniqueKey-constraint-fields($model)
      let $uniqueKey-search := domain:get-model-uniqueKey-constraint-query($model,$params,$mode)
      return
        if($uniqueKey-search) then
          <validationError>
            <element>{$uniqueKey-constraints/fn:data(@name)}</element>
            <type>uniqueKey</type>
            <error>Instance is not unique. Keys:{fn:string-join($uniqueKey-constraints/fn:data(@name),", ")}</error>
          </validationError>
        else (),
      for $element in $model//(domain:attribute | domain:element)
      let $name := fn:data($element/@name)
      let $key := domain:get-field-id($element)
      let $type := domain:resolve-datatype($element)
      let $value := domain:get-field-value($element,$params)
      let $value := if(fn:exists($value)) then $value else $element/@default
      let $occurence := $element/@occurrence
     return
      (
        if( fn:data($occurence) eq "?" and fn:not(fn:count($value) <= 1) )  then
          <validationError>
            <element>{$name}</element>
            <type>{fn:local-name($occurence)}</type>
            <typeValue>{fn:data($occurence)}</typeValue>
            <error>The value of {$name} must have zero or one value.</error>
          </validationError>
        else if( fn:data($occurence) eq "+" and fn:not(fn:count($value) >= 1) ) then
          <validationError>
            <element>{$name}</element>
            <type>{fn:local-name($occurence)}</type>
            <typeValue>{fn:data($occurence)}</typeValue>
            <error>The value of {$name} must contain at least one item.</error>
          </validationError>
        else if( fn:data($occurence) eq "1" and fn:not(fn:count($value) = 1) ) then
          <validationError>
            <element>{$name}</element>
            <type>{fn:local-name($occurence)}</type>
            <typeValue>{fn:data($occurence)}</typeValue>
            <error>The value of {$name} must contain exactly one item.</error>
          </validationError>
        else (),

        for $attribute in $element/domain:constraint/@*
        return
          typeswitch($attribute)
            case attribute(required) return
              if(fn:data($attribute) = "true" and fn:not(fn:exists($value))) then
                <validationError>
                  <element>{$name}</element>
                  <type>{fn:local-name($attribute)}</type>
                  <typeValue>{fn:data($attribute)}</typeValue>
                  <error>The value of {$name} can not be empty.</error>
                </validationError>
              else ()
            case attribute(minLength) return
              let $minLength := xs:integer(fn:data($attribute))
              return
                if(some $item in $value satisfies fn:string-length($item) lt $minLength ) then
                  <validationError>
                    <element>{$name}</element>
                    <type>{fn:local-name($attribute)}</type>
                    <typeValue>{fn:data($attribute)}</typeValue>
                    <error>The length of {$name} must be longer than {fn:data($attribute)}.</error>
                  </validationError>
                else ()
            case attribute(maxLength) return
              let $maxLength := xs:integer(fn:data($attribute))
              return
                if(some $item in $value satisfies fn:string-length($item) gt $maxLength ) then
                  <validationError>
                    <element>{$name}</element>
                    <type>{fn:local-name($attribute)}</type>
                    <typeValue>{fn:data($attribute)}</typeValue>
                    <error>The length of {$name} must be shorter than {fn:data($attribute)}.</error>
                  </validationError>
                else ()
            case attribute(minValue) return
              let $minValue := xdmp:value(fn:concat("fn:data($attribute) cast as ", $type))
              let $value := xdmp:value(fn:concat("for $v in $value return $v cast as ", $type))
              return
                if(some $item in $value satisfies $item lt $minValue) then
                  <validationError>
                    <element>{$name}</element>
                    <type>{fn:local-name($attribute)}</type>
                    <typeValue>{fn:data($attribute)}</typeValue>
                    <error>The value of {$name} must be at least {$minValue}.</error>
                  </validationError>
                else ()
            case attribute(maxValue) return
              let $maxValue := xdmp:value(fn:concat("fn:data($attribute) cast as ", $type))
              let $value := xdmp:value(fn:concat("for $v in $value return $v cast as ", $type))
              return
                if(some $item in $value satisfies $item gt $maxValue) then
                  <validationError>
                    <element>{$name}</element>
                    <type>{fn:local-name($attribute)}</type>
                    <typeValue>{fn:data($attribute)}</typeValue>
                    <error>The value of {$name} must be no more than {$maxValue}.</error>
                  </validationError>
                else ()
            case attribute(inList) return
              let $options := domain:get-field-optionlist($element)
              return
                if(some $item in $value satisfies fn:not($item = $options/domain:option)) then
                  <validationError>
                    <element>{$name}</element>
                    <type>{fn:local-name($attribute)}</type>
                    <typeValue>{fn:data($attribute)}</typeValue>
                    <error>The value of {$name} must be one of the following values [{fn:string-join($options,", ")}].</error>
                  </validationError>
                 else ()
            case attribute(pattern) return
              if(some $item in $value satisfies fn:not(fn:matches($item,fn:data($attribute)))) then
                <validationError>
                  <element>{$name}</element>
                  <type>{fn:local-name($attribute)}</type>
                  <typeValue>{fn:data($attribute)}</typeValue>
                  <error>The value of {$name} must match the regular expression {fn:data($attribute)}.</error>
                </validationError>
               else ()
            case attribute(validator) return
              let $function-name := fn:string($attribute)
              let $validator-function := domain:get-model-function((), $model/@name, $function-name, 3, fn:false())
              (:let $validator-function := model:get-function-cache($validator-function):)
              return
                if (fn:exists($validator-function)) then
                  $validator-function($element, $params, $mode)
                else
                  ()
            default return ()
      )
    )
    return
      if (fn:empty($validation-errors)) then
        ()
      else
        fn:error(
          xs:QName("MODEL-VALIDATION-FAILED"),
          text{"Validation failed for model", $model/@name, "mode", $mode},
          map:entry("validation-errors", <validationErrors>{$validation-errors}</validationErrors>)
        )
};

declare function model:validation-errors(
  $error as element(error:error)
) as element (validationErrors)? {
  if (fn:starts-with($error/error:data/error:datum, "map:map(") and fn:ends-with($error/error:data/error:datum, ")")) then
    map:get(xdmp:value($error/error:data/error:datum/text()), "validation-errors")
  else
    ()
};

(:~
 :
 :)
declare function model:put(
  $model as element(domain:model),
  $body as item()
) {
  model:create($model,$body)
};

(:~
 :
 :)
declare function model:post(
  $model as element(domain:model),
  $body as item()
)  {
  let $params := model:build-params-map-from-body($model,$body)
  return model:update($model,$params)
};

(:~
 :  Takes a simple xml structure and assigns it to a map
 :  Does not handle nested content models
 :)
declare function model:build-params-map-from-body(
  $model as element(domain:model),
  $body as node()
) as map:map {
  let $params := map:map()
  let $body := if($body instance of document-node()) then $body/element() else $body
  let $_ :=
    for $xmlNode in $body/element()
    return map:put($params,fn:local-name($xmlNode),$xmlNode/node()/fn:data(.))
  return $params
};

declare function model:convert-to-map(
  $model as element(domain:model),
  $current as item()
) as map:map? {
  typeswitch($current)
    case json:object
      return map:new((
        for $field in $model//(domain:element|domain:attribute)
          return map:entry(domain:get-field-name-key($field), domain:get-field-value($field, $current))
      ))
    case element()
      return map:new((
        for $field in $model//(domain:element|domain:attribute)
          return map:entry(domain:get-field-name-key($field), domain:get-field-value($field, $current))
      ))
    case map:map
      return $current
    default
      return ()
};

(:~
 :  Builds the value for a given field type.
 :  This ensures that the proper values are set for the given field
 :)
declare function model:build-value(
  $context as element(),
  $value as item()*,
  $current as item()*)
{
  let $type := $context/@type
  return
    switch($type)
    case "id" return
        if(fn:exists($current))
        then $current
        else if(fn:exists($value)) then $value
        else model:generate-fnid(($value,<x>{xdmp:random()}</x>)[1])
    case "identity" return
        if(fn:exists($current))
        then fn:data($current)
        else if (fn:exists($value) and fn:normalize-space($value) ne "" )
        then fn:data($value)
        else model:get-identity()
    case "reference" return
        model:get-references($context,$value)
    case "update-timestamp" return
        fn:current-dateTime()
    case "update-user" return
        context:user()
    case "create-timestamp" return
        if(fn:exists($current))
        then $current
        else fn:current-dateTime()
    case "create-user" return
        if(fn:exists($current))
        then $current
        else context:user()
    case "query" return
        cts:query($value)
    default return
     if($type = $domain:SIMPLE-TYPES) then fn:data($value)
     else fn:error((),"UNKNOWN-TYPE",$type)
};

(:~
 : Finds any element by a field name.  Important to only pass field names using special syntax
 :  "fieldname==" Equality
 :  "!fieldname=" Not Equality
 :  "fieldname>"  Greater Than (range only)
 :  "fieldname<"  Less Than (range only)
 :  "fieldname>=" Greater Than Equal To (range only)
 :  "fieldname<=" Less Than Equal To
 :  "fieldname.."  Between two values map must have 2 values of type assigned to field
 :  "!fieldname.." Negated between operators
 :  "fieldname*="  Word Wildcard Like Ex
 :  "!name*=" Any word or default
 :  "fieldname"  - performs a value query
 :  "join"
 :)
declare function model:find(
  $model as element(domain:model),
  $params
) {
  let $search := model:find-params($model,$params)
  let $persistence := $model/@persistence
  let $name := $model/@name
  let $namespace := domain:get-field-namespace($model)
  let $model-qname := fn:QName($namespace,$name)
  return
    if ($persistence = 'document') then
      let $path := $model/domain:document/text()
      return
        fn:doc($path)/*/*[cts:contains(.,cts:and-query(($search)))]
    else if($persistence = 'directory') then
      cts:search(
        fn:collection(),
        cts:and-query((
          cts:directory-query($model/domain:directory/text()),
          cts:element-query($model-qname, $search)
        ))
      )
    else if($persistence = "abstract") then
      cts:search(fn:collection(),cts:or-query(domain:get-descendant-model-query($model)))
    else fn:error(xs:QName("INVALID-PERSISTENCE"),"Invalid Persistence", $persistence)
};
(:~
 :  "fieldname==" Equality
 :  "fieldname!=" Not Equality
 :  "fieldname>"  Greater Than (range only)
 :  "fieldname<"  Less Than (range only)
 :  "fieldname>=" Greater Than Equal To (range only)
 :  "fieldname<=" Less Than Equal To
 :  "fieldname.."  Between two values map must have 2 values of type assigned to field
 :  "!fieldname.." Negated between operators
 :  "fieldname*="  Word Wildcard Like Ex
 :  "!name*=" Any word or default
 :  "fieldname"  - performs a value query
 :)
declare function model:find-params(
  $model as element(domain:model),
  $params
) {
   let $queries :=
    for $k in domain:get-param-keys($params)[fn:not(. = "_join")]
        let $parts    := fn:analyze-string($k, "^(\i\c*)(==|!=|>=|>|<=|<|\.\.|)?$")
        let $opfield  := $parts/*:match/*:group[@nr eq 1]
        let $operator := $parts/*:match/*:group[@nr eq 2]
        let $field    := domain:get-model-field($model,$opfield)
        let $stype    := (domain:navigation($field)/@searchType, "value")[1]
        let $ns       := domain:get-field-namespace($field)
        let $qname    := fn:QName($ns,$field/@name)
        let $is-reference
                      := $field/@type="reference"
        let $query    :=
          if($operator eq "==" and fn:not($is-reference)) then
            if($stype eq "range" )
            then cts:element-range-query($qname,"=",domain:get-param-value($params,$k))
            else cts:element-value-query($qname,domain:get-param-value($params,$k))
          else if($operator eq "=="  and $is-reference) then
            (:ismap a reference process as such:)
            if($stype eq "range")
            then cts:element-attribute-range-query($qname,xs:QName("ref-id"), "=", domain:get-param-value($params,$k))
            else cts:element-attribute-value-query($qname,xs:QName("ref-id"),domain:get-param-value($params,$k))
          else if($operator eq "!=") then
            if($stype eq "range")
            then cts:element-range-query($qname,"!=",domain:get-param-value($params,$k))
            else cts:not-query(cts:element-value-query($qname,domain:get-param-value($params,$k)))
          else if($operator = (">",">=","<=","<"))then
            if($stype eq "range")
            then  cts:element-range-query($qname,$operator,domain:get-param-value($params,$k))
            else fn:error(xs:QName("FIND-RANGE-NOT-VALID"),"Must enable range index for field using operator",fn:string($field/@name))
          else if($operator eq "..") then
            if($stype eq "range")
            then cts:and-query((
              cts:element-range-query($qname,">=",domain:get-param-value($params,$k)[1]),
              cts:element-range-query($qname,"<=",domain:get-param-value($params,$k)[2])
            ))
            else fn:error(xs:QName("FIND-RANGE-NOT-VALID"),"Must enable range index for field using operator",fn:string($field/@name))
          else if($operator eq "*=") then
            cts:element-word-query($qname,domain:get-param-value($params,$k))
          else
            typeswitch($field)
              case element(domain:attribute) return
                let $parent := domain:get-parent-field-attribute($field)
                return cts:element-attribute-word-query(domain:get-field-qname($parent),xs:QName($field/@name), domain:get-param-value($params,$k))
              case element(domain:element) return
                cts:element-word-query($qname,domain:get-param-value($params,$k))
              default return fn:error(xs:QName("FIND-PARAMS-ERROR"),"Unsupported field type")
      return
         $query
  let $join := (domain:get-param-value($params,"_join"),"and")[1]
  return
    if($join eq "or")
    then cts:or-query($queries)
    else cts:and-query(($queries))
};

declare function partial-update(
    $model as element(domain:model),
    $updates as map:map
 ) {
    let $current := model:get($model,$updates)
    let $identity-field := domain:get-model-identity-field-name($model)
    return
        for $upd-key in map:keys($updates)
        let $context := $model//(domain:element|domain:attribute)[@name eq $upd-key]
        let $key   := domain:get-field-id($context)
        let $current-value := domain:get-field-value($context,$current)
        let $build-node := model:recursive-build($context,$current-value,$updates,fn:true())
        where $context/@name ne $identity-field
        return
            xdmp:node-replace($current-value,$build-node)
};
(:~
 :  Finds particular nodes based on a model and updates the values
 :)
declare function model:find-and-update($model,$params) {
   ()
};
(:~
 : Collects the parameters
 :)
(:
declare function model:build-find-and-update-params(
    $model,
    $params) {
  let $final-map := map:map()
  let $upd-map := map:map()
  let $del-map := map:map()
  let $ins-map := map:map()
  let $col-map := map:map()
  let $_ :=
    for $k in map:keys($params)
    let $t := fn:tokenize($k,":")
    return
      switch($t[1])
       (:Query:) case "q" return map:put($final-map,"query",$
       (:Update:)case "u" return map:put($
       (:Delete:)case "d" return
       (:Insert:)case "i" return
       (:Collection:)case "c" return
  return $update-map
};:)

declare function model:export(
  $model as element(domain:model),
  $params as map:map
) as element(results) {
  model:export($model, $params, ())
};

(:~
 : Returns if the passed in _query param will be used as search criteria
 : $params support all model:list-params parameters
 : $fields optional return field list (must be marked as exportable=true)
~:)
declare function model:export(
  $model as element(domain:model),
  $params as map:map,
  $fields as xs:string*
) as element(results) {
  let $results := model:list($model, $params)
  let $filter-mod := $model
  let $convert-attributes := xs:boolean(domain:get-param-value($params, "_convert-attributes"))
  let $export-fields := (
    domain:get-field-name-key(domain:get-model-identity-field($model)),
    if ($fields) then
      for $field in $model//*[domain:navigation/@exportable="true" and domain:get-field-name-key(.) = $fields]
      return
        domain:get-field-name-key($field)
    else
      for $field in $model//*[domain:navigation/@exportable="true"](:/@name:)
      return
        domain:get-field-name-key($field)
  )
  return
    element results {
    element header {
      element {fn:QName(domain:get-field-namespace($filter-mod),$filter-mod/@name)} {
        for $field in $filter-mod//(domain:element|domain:attribute)[domain:get-field-name-key(.) = $export-fields]
        return element {fn:QName(domain:get-field-namespace($field), domain:get-field-name-key($field))} {fn:data($field/@label)}
      }
    },
    element body {
      for $f in $results/*[fn:local-name(.) eq $filter-mod/@name]
      return
        element {fn:node-name($f)} {
          convert-attributes-to-elements(domain:get-field-namespace($filter-mod), $f/@*[name(.) = $export-fields], $convert-attributes),
          serialize-to-flat-xml(domain:get-field-namespace($f), $model, $f)[fn:local-name(.) = $export-fields]
        }
    }
  }

};

declare function convert-attributes-to-elements($namespace as xs:string, $attributes, $convert-attributes) {
  if ($convert-attributes) then
    for $attribute in $attributes
    return
      element {fn:QName($namespace, fn:name($attribute))} {xs:string($attribute)}
  else
    $attributes
};

declare function serialize-to-flat-xml(
  $namespace as xs:string,
  $model as element(domain:model),
  $current as node()
) {
  let $map := model:convert-to-map($model, $current)
  return
    for $key in map:keys($map)
    let $values := domain:get-param-value($map, $key)
    return
      element { fn:QName($namespace, $key) } {
      if(fn:count($values) gt 1) then fn:string-join(($values ! fn:normalize-space(.)),"|") else $values}
};

declare function convert-flat-xml-to-map(
  $model as element(domain:model),
  $current as node()
) as map:map {
  let $map := map:map()
  let $_ := (
    map:put($map,domain:get-field-name-key(domain:get-model-identity-field($model)), domain:get-field-value(domain:get-model-identity-field($model), $current)),
    for $field in $current/*
    let $values :=  $field

    return
      map:put($map,fn:local-name($field),if(fn:count($values) gt 1) then
        fn:tokenize($values,"\|") else $values
      )
  )
  return $map
};

declare function model:import(
  $model as element(domain:model),
  $dataset as element(results)
) as empty-sequence() {
  let $_ :=
    for $doc in $dataset/body/*
      let $map := convert-flat-xml-to-map($model, $doc)
      return model:update-partial($model, $map)
  return ()
};

(:~
 : Creates a domain object from its json representation
~:)
declare function model:from-json(
  $model as element(domain:model),
  $update as item()
) {
  model:from-json($model,$update,(),"create")
};

(:~
 : Creates a new domain instance from a json representation
~:)
declare function model:from-json(
  $model as element(domain:model),
  $update as item(),
  $current as element()?,
  $mode as xs:string
) {
  switch($mode)
    case "create" return model:build-from-json($model,$current,$update,fn:false())
    case "update" return model:build-from-json($model,$current,$update,fn:true())
    case "clone" return ()
    default return fn:error(xs:QName("UNKNOWN-CREATE-MODE"), "Cannot process mode",$mode)
};

(:~
 : Deserializes a model instance from a json representation
 :)
declare function model:build-from-json(
  $context as element(),
  $current as element()?,
  $updates as element(),
  $partial as xs:boolean
) {
   let $type := fn:data($context/@type)
   let $key  := domain:get-field-id($context)
   let $current-value := domain:get-field-value($context,$current)
   let $default-value := fn:data($context/@default)
   let $base-type := domain:get-base-type($context)
   return
   typeswitch($context)
   (: Build out any domain Models :)
   case element(domain:model) return
        let $attributes :=
            for $a in $context/domain:attribute
            return
               model:build-from-json($a, $current,$updates,$partial)
        let $ns := domain:get-field-namespace($context)
        let $nses := model:get-namespaces($context)
        let $localname := fn:data($context/@name)
        let $default   := fn:data($context/@default)
        return
            element {(fn:QName($ns,$localname))} {
                for $nsi in $nses
                return
                  namespace {$nsi/@prefix}{$nsi/@namespace-uri},
                $attributes,
                for $n in $context/(domain:element|domain:container)
                return
                    model:build-from-json($n,$current,$updates,$partial)
            }
     (: Build out any domain Elements :)
     case element(domain:element) return
        let $attributes :=
            $context/domain:attribute ! model:build-from-json(.,$current, $updates,$partial)
        let $ns := domain:get-field-namespace($context)
        let $localname := fn:data($context/@name)
        let $default   := (fn:data($context/@default),"")[1]
        let $occurrence := ($context/@occurrence,"?")
        let $json-values := domain:get-field-json-value($context, $updates)
        return
          switch($base-type)
          case "simple" return model:build-simple($context,$current,$updates,$partial)
          case "complex" return model:build-complex($context,$current,$updates,$partial)
          case "instance" return model:build-instance($context,$current,$updates,$partial)
          default return fn:error(xs:QName("UNKNOWN-COMPLEX-TYPE"),"The type of " || $type || " is unknown ",$context)

     (: Build out any domain Attributes :)
     case element(domain:attribute) return model:build-attribute($context,$current,$updates,$partial, fn:false())
     case element(domain:triple) return model:build-triple($context,$current,$updates,$partial)
     (: Build out any domain Containers :)
     case element(domain:container) return
        let $ns := domain:get-field-namespace($context)
        let $localname := fn:data($context/@name)
        return
          element {(fn:QName($ns,$localname))}{
           for $n in $context/(domain:attribute|domain:element|domain:container)
           return
             model:build-from-json($n, $current ,$updates,$partial)
           }
     (: Return nothing if the type is not of Model, Element, Attribute or Container :)
     default return fn:error(xs:QName("UNKNOWN-SIMPLE-TYPE"),"The type of " || $type || " is unknown ",$context)

};

(:~
 : Creates a complex element
~:)
declare function build-complex(
  $context as node(),
  $current as node()?,
  $updates as item(),
  $partial as xs:boolean
) {
 (:Process Complex Types:)
 let $type := $context/@type
 let $current-value := domain:get-field-value($context,$current)
 let $update-value  := domain:get-field-value($context,$updates)
 return
    switch($type)
      case "reference"      return model:build-reference($context,$current-value,$update-value,$partial)
      case "binary"         return model:build-binary($context,$current-value,$update-value,$partial)
      case "schema-element" return model:build-schema-element($context,$current-value,$update-value,$partial)
      case "triple"         return model:build-triple($context,$current-value,$update-value,$partial)
      case "langString"     return model:build-langString($context,$current-value,$update-value,$partial)
      default return
          if($type = ($domain:COMPLEX-TYPES)) then
             if(fn:exists($update-value) and $context/@occurrence = ("*","+")) then
                 for $value in $update-value
                 return
                    element {domain:get-field-qname($context)}{
                       model:build-value($context,$value,$current-value)
                     }
              else if($partial and $current-value) then
                    $current-value
              else element {domain:get-field-qname($context)}{
                       model:build-value($context, $update-value, $current-value)
                   }
         else fn:error(xs:QName("UNKNOWN-TYPE"),"The type of " || $type || " is unknown ",$context)
};

(:~
 : Creates a simple type as defined by domain:SIMPLE-TYPES
 :)
declare function build-simple(
  $context as node(),
  $current as node()?,
  $updates as item()?,
  $partial as xs:boolean
) {
    let $occurrence := $context/@occurrence
    let $default    := $context/@default
    let $fixed      := $context/@fixed
    let $values := domain:get-field-json-value($context,$updates)
    return
      typeswitch($context)
        case element(domain:element) return
            if(domain:field-is-multivalue($context))
            then
               for $v in $values
               return
                   element {domain:get-field-qname($context)}{
                     $v
                   }
            else
               element {domain:get-field-qname($context)}{
                  if($context/(@nillable|@nullable and fn:empty($values)) = "true") then attribute xsi:nillable{fn:true()} else (),
                  $values
               }
        case element(domain:attribute) return
            attribute {domain:get-field-qname($context)} {
               $updates ! domain:get-field-json-value($context,.)
            }
        default return fn:error(xs:QName("UNSUPPORTED-FIELD-TYPE"),"Cannot Support field Type",fn:node-name($context))
 };

(:Normalizes the path to ensure // are removed:)
declare function model:normalize-path($path as xs:string) {
  let $computed := fn:string-join(fn:tokenize($path,"/+")[. ne ""],"/")
  return
    if(fn:starts-with($computed,"/"))
    then $computed
    else fn:concat("/",$computed)
};
