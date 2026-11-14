@echo off
rem Windows shim for the Python mock AWS CLI (tests/mock/aws). Put tests\mock\win first on PATH.
python "%~dp0..\aws" %*
