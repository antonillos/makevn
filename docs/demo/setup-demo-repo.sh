#!/usr/bin/env bash
set -euo pipefail

mode="${1:-developer}"
repo="${2:-${MAKEVN_DEMO_REPO:-/tmp/makevn-demo-repo}}"

rm -rf "${repo}"
mkdir -p \
  "${repo}/module-a/src/main/java/com/example" \
  "${repo}/module-a/src/test/java/com/example"

cat > "${repo}/pom.xml" <<'EOF'
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>makevn-demo-parent</artifactId>
  <version>1.0.0-SNAPSHOT</version>
  <packaging>pom</packaging>
  <modules>
    <module>module-a</module>
  </modules>
  <properties>
    <maven.compiler.release>17</maven.compiler.release>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
    <junit.version>5.12.2</junit.version>
    <jacoco.version>0.8.13</jacoco.version>
  </properties>
</project>
EOF

cat > "${repo}/module-a/pom.xml" <<'EOF'
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <parent>
    <groupId>com.example</groupId>
    <artifactId>makevn-demo-parent</artifactId>
    <version>1.0.0-SNAPSHOT</version>
  </parent>
  <artifactId>module-a</artifactId>
  <dependencies>
    <dependency>
      <groupId>org.junit.jupiter</groupId>
      <artifactId>junit-jupiter</artifactId>
      <version>${junit.version}</version>
      <scope>test</scope>
    </dependency>
  </dependencies>
  <build>
    <plugins>
      <plugin>
        <groupId>org.jacoco</groupId>
        <artifactId>jacoco-maven-plugin</artifactId>
        <version>${jacoco.version}</version>
        <executions>
          <execution>
            <goals>
              <goal>prepare-agent</goal>
            </goals>
          </execution>
          <execution>
            <id>report</id>
            <phase>verify</phase>
            <goals>
              <goal>report</goal>
            </goals>
          </execution>
        </executions>
      </plugin>
    </plugins>
  </build>
</project>
EOF

cat > "${repo}/module-a/src/main/java/com/example/Calculator.java" <<'EOF'
package com.example;

public final class Calculator {
    public int add(int left, int right) {
        return left + right;
    }
}
EOF

cat > "${repo}/module-a/src/test/java/com/example/CalculatorTest.java" <<'EOF'
package com.example;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class CalculatorTest {
    private final Calculator calculator = new Calculator();

    @Test
    void addsNumbers() {
        assertEquals(5, calculator.add(2, 3));
    }
}
EOF

git init --quiet --initial-branch=main "${repo}"
git -C "${repo}" add .
git -C "${repo}" \
  -c user.name="makevn demo" \
  -c user.email="demo@makevn.dev" \
  commit --quiet -m "Initial Java project"

if [[ "${mode}" == "agent" ]]; then
  cat > "${repo}/module-a/src/main/java/com/example/Calculator.java" <<'EOF'
package com.example;

public final class Calculator {
    public int add(int left, int right) {
        return left + right;
    }

    public int subtract(int left, int right) {
        return left - right;
    }
}
EOF

  cat > "${repo}/module-a/src/test/java/com/example/CalculatorTest.java" <<'EOF'
package com.example;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class CalculatorTest {
    private final Calculator calculator = new Calculator();

    @Test
    void addsNumbers() {
        assertEquals(5, calculator.add(2, 3));
    }

    @Test
    void subtractsNumbers() {
        assertEquals(3, calculator.subtract(5, 2));
    }
}
EOF
fi

printf '%s\n' "${repo}"
