@echo off
if NOT exist *.mp3 exit
if exist "_PlayInfo.m3u" exit
echo #>_PlayInfo.m3u
CHCP 65001>nul
dir *.mp3 /b/o:n >>_PlayInfo.m3u

