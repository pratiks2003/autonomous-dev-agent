const { jestConfig } = require("@salesforce/sfdx-lwc-jest/config");

module.exports = {
  testPathIgnorePatterns: [
    "<rootDir>/node_modules/",
    "<rootDir>/agent-forge-template/"
  ],
  ...jestConfig,
  modulePathIgnorePatterns: ["<rootDir>/.localdevserver"]
};
