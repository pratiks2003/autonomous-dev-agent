const { jestConfig } = require("@salesforce/sfdx-lwc-jest/config");

module.exports = {
  ...jestConfig,
  testPathIgnorePatterns: ["<rootDir>/node_modules/", "<rootDir>/agent-forge-template/"],
  modulePathIgnorePatterns: ["<rootDir>/.localdevserver"]
};
