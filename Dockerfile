#multistage Dockerfile for JAVA_Project

FROM maven AS buildstage
RUN mkdir /opt/Java_Project
WORKDIR /opt/Java_Project
COPY . .
RUN mvn clean install 


FROM tomcat
WORKDIR webapps
COPY --from=buildstage /opt/Java_Project/target/*.war .
RUN rm -rf ROOT && mv *.war ROOT.war
EXPOSE 8080


#This is sandy testing the dev - PR
