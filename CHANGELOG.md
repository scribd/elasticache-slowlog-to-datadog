# [1.2.0](https://github.com/scribd/elasticache-slowlog-to-datadog/compare/v1.1.0...v1.2.0) (2020-06-10)


### Features

* Add support for the 4 permutations of Elasticache redis endpoints ([67f0526](https://github.com/scribd/elasticache-slowlog-to-datadog/commit/67f0526e41b049ffcaee3b14689ae60a1e4cf7e8))

# [1.1.0](https://github.com/scribd/elasticache-slowlog-to-datadog/compare/v1.0.1...v1.1.0) (2020-05-05)


### Bug Fixes

* do not report a bucket we've already reported && do not report a bucket that has not completed. ([9dbd02e](https://github.com/scribd/elasticache-slowlog-to-datadog/commit/9dbd02eb64447ad00691ff498f5b44f56f4d43c6))


### Features

* When slowlogs no longer appear following a slowlog event, post a zero for that command. ([ed7b094](https://github.com/scribd/elasticache-slowlog-to-datadog/commit/ed7b0940d955c239e554ed69e7bd5f90cbe7f52a))

## [1.0.1](https://github.com/scribd/elasticache-slowlog-to-datadog/compare/v1.0.0...v1.0.1) (2020-04-29)


### Bug Fixes

* Get the whole redis slowlog, rather than just 10 ([bbbfa48](https://github.com/scribd/elasticache-slowlog-to-datadog/commit/bbbfa489f6f1a649b74a89f404db797823f202d8))

# 1.0.0 (2020-04-27)


### Bug Fixes

* correct unit descriptions ([a2d7b55](https://github.com/scribd/elasticache-slowlog-to-datadog/commit/a2d7b55a62b875bcc6b119434f77ae1ef927ba4f))
* typo in branch names ([a4c7698](https://github.com/scribd/elasticache-slowlog-to-datadog/commit/a4c7698e9b68624d26d922091d2b351be8f5a819))
* use SSM_PATH parameter ([599ef24](https://github.com/scribd/elasticache-slowlog-to-datadog/commit/599ef24195d37a97f4395e584899f3af90dad717))
* use UTC for Time dependent functions ([2f004c9](https://github.com/scribd/elasticache-slowlog-to-datadog/commit/2f004c9fa367f78ca51f4ee5612b82b6fe578017))


### Features

* add documentation ([38a7ecf](https://github.com/scribd/elasticache-slowlog-to-datadog/commit/38a7ecfef338462b15db540aac48d8aab10a1563))
* Configure metric metadata upon startup ([55cb30a](https://github.com/scribd/elasticache-slowlog-to-datadog/commit/55cb30a5df8c5a595c220a8abbec1169e9fb030c))
* enable usage of AWS SSM to supply environment variables ([bb92bd3](https://github.com/scribd/elasticache-slowlog-to-datadog/commit/bb92bd32a9c158dc75c0012b06cd6f7c3aea2f4c))
* make the worst case scenario an hour ago, ([732dd38](https://github.com/scribd/elasticache-slowlog-to-datadog/commit/732dd38feaca1aea5a3525b78682d21b9081bc01))
* slowlog injection accepts argument for time ([95baab4](https://github.com/scribd/elasticache-slowlog-to-datadog/commit/95baab4cdccde4468e3d9c7e2ee2ddcbfdad637a))
* submit histogram of metrics on a minute-by-minute basis ([92431b4](https://github.com/scribd/elasticache-slowlog-to-datadog/commit/92431b4ef22d89f078e9e64d4e63c719454095c7))
* test the program with rspec ([eaa4d29](https://github.com/scribd/elasticache-slowlog-to-datadog/commit/eaa4d29262a7d516b9e727da87d7ded864537782))
