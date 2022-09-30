package = "lua-resty-kcp"
version = "dev-1"
source = {
   url = "git+https://github.com/fesily/lua-resty-kcp.git"
}
description = {
   homepage = "https://github.com/fesily/lua-resty-kcp",
   license = "Apache-2.0"
}
build = {
   type = "builtin",
   modules = {
      ["resty.kcp.init"] = "lib/resty/kcp/init.lua",
      ["resty.kcp.libkcp"] = "lib/resty/kcp/libkcp.lua",
      libkcp = {
         sources = {"kcp/ikcp.c"}
      }
   }
}