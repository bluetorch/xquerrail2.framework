(:
Copyright 2014 MarkLogic Corporation

XQuerrail - blabla
:)

xquery version "1.0-ml";
(:~Responsible for refreshing the application cache for all servers including task server.
   The application cache expands all the domains includes and keeps them in a server variable 
   corresponding the the configuration uri.
 :)
import module namespace config ="http://xquerrail.com/config" at "config.xqy";
config:refresh-app-cache(),
xdmp:spawn("initialize-taskserver.xqy")

