
buildscript {
    // ext.kotlin_version = '1.7.10'
    repositories {
        maven("https://maven.aliyun.com/repository/public/")
        maven("https://maven.aliyun.com/repository/spring/")
        maven("https://maven.aliyun.com/repository/google/")
        maven("https://maven.aliyun.com/repository/gradle-plugin/")
        maven("https://maven.aliyun.com/repository/spring-plugin/")
        maven("https://maven.aliyun.com/repository/grails-core/")
        maven("https://maven.aliyun.com/repository/apache-snapshots/")
        google()
        mavenCentral()
    }

    // dependencies {
    //     classpath 'com.android.tools.build:gradle:7.3.0'
    //     classpath "org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlin_version"
    // }
}

allprojects {
    repositories {
        // fix flutter run 超时 Gradle 在尝试从网络下载依赖时连接超时
        // 替换为阿里云镜像
        maven("https://maven.aliyun.com/repository/public/")
        maven("https://maven.aliyun.com/repository/spring/")
        maven("https://maven.aliyun.com/repository/google/")
        maven("https://maven.aliyun.com/repository/gradle-plugin/")
        maven("https://maven.aliyun.com/repository/spring-plugin/")
        maven("https://maven.aliyun.com/repository/grails-core/")
        maven("https://maven.aliyun.com/repository/apache-snapshots/")
        // 作者：易秋
        // 链接：https://juejin.cn/post/7299346813261676544
        // 来源：稀土掘金
        // 著作权归作者所有。商业转载请联系作者获得授权，非商业转载请注明出处。


        // 可选：保留原始源作为备选
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
