module.exports = {
  "plugins": [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    [
      "@semantic-release/changelog",
      {
        "changelogFile": "CHANGELOG.md"
      }
    ],
    [
      "@semantic-release/github",
      {
        "assets": [
          {
            "path": "slowlog_check.zip",
            "name": "slowlog_check.${nextRelease.version}.zip",
            "label": "Full zip distribution"
          }
        ]
      }
    ]
  ]
};
