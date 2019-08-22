@Library('ethan-shared-library@master') _

def label = "mypod-${UUID.randomUUID().toString()}"
def serviceaccount = "che"
podTemplate(label: label, serviceAccount: serviceaccount, containers: utils.getcontainer(),
volumes: [
  hostPathVolume(mountPath: '/var/run/docker.sock', hostPath: '/var/run/docker.sock')
])
{
    node(label) {
	    def BRANCH_NAME = env.BRANCH_NAME 
        def DOCKER_HUB_ACCOUNT = "projectethan007"
        def DOCKER_IMAGE_NAME = "ad"
        def DOCKER_CONTAINER_NAME = "ad"
		def K8S_DEPLOYMENT_NAME = DOCKER_IMAGE_NAME
		def CLAIR_URL = "http://clair:6060"
		def NAMESPACE = "ethan"
		def TARGET_BRANCH = "dev"
		def REPO_NAME = "anomaly-detection-docker"
        def ST2_API_KEY = "YjQwYmU0ZTQ3NWY3NTQ5OGQzN2I4OTIwYmFhYzNhODRiNjMxZTdmOWI5MDQzMGQxMDI4YTlmZTAxNGZmMzZjZA"
		def APPURL = "a44d160acf77911e891f9021c795881b-1755940959.eu-west-1.elb.amazonaws.com/index"
		def JHOST =  "https://a44d160acf77911e891f9021c795881b-1755940959.eu-west-1.elb.amazonaws.com/index"
	    
	    env.JAVA_HOME="/usr/bin/java"
		def scannerHome = tool 'Sonar Scanner';

              
		    stage('Checkout'){     
                checkout scm
				def TAG = utils.getTag()
				env.TAG = TAG
				echo "TAG ----> ${TAG}"
				def message = utils.getpullreqvar()
				env.message = message	
            }

            stage('Scanning Secrets') {
		        container('git-secrets') {
					utils.scan_sec()
		        }   
		    }
             
        
			stage('SonarQube analysis') {
			    container('jdk') {
			        withSonarQubeEnv('SonarQube') {
			            sh "${scannerHome}/bin/sonar-scanner" 
			        }
                }
            }
        
	
            stage('Docker Build'){
                container('docker'){
                    docker.withRegistry('https://docker.io.com/v2/', 'MY_DOCKER_TEST_ID') {

                        sh """
                            docker build --network=host -t "${DOCKER_HUB_ACCOUNT}/${DOCKER_IMAGE_NAME}:${TAG}" .
							docker tag ${DOCKER_HUB_ACCOUNT}/${DOCKER_IMAGE_NAME}:${TAG} ${DOCKER_HUB_ACCOUNT}/${DOCKER_IMAGE_NAME}:latest	
                        """
                    }
                }  
             }
             
             
			stage ('Docker image scan') {
				container('clair-scanner') {	
			        sh """
						clair-scanner -w 'mywhitelist.yaml' -c ${CLAIR_URL} --ip='clair-scanner' -t 'High' ${DOCKER_HUB_ACCOUNT}/${DOCKER_IMAGE_NAME}:${TAG}
					"""
			   }
			}  
        

		if(env.BRANCH_NAME =~ /feature*/){
			stage('Pull Request'){
                container('kubectl'){ 
                    checkout scm 
                    echo 'Feature branch name: ' +env.BRANCH_NAME
					echo "Commit Message: ${message}"
					
                    sh """ 
                        echo "---- Pull Request ----"
					
                        \$(echo "$message" | grep -iEq "pull req") && kubectl get pods  -l app=stackstorm | grep -v NAME | cut -d ' ' -f1 | xargs -n 1 -I{} kubectl exec {} -- bash -c "st2 run jenkins.pull_req_workflow repo="${REPO_NAME}" summary='raising pull request' source_branch_name="${BRANCH_NAME}" target_branch_name="${TARGET_BRANCH}"" |tee -a st2.log  || echo "Not raising pull request"

						if [[ -f "st2.log" ]]
						then						
							errcount=\$(grep -e 'Pull request update failed' -e 'Pull request creation failed' st2.log|wc -l)
							if [[ "\$errcount" -gt 0 ]] 
							then
								echo "Exiting"
								exit 1
							else 
								echo "Executed successfully"
							fi
						fi	
							
                    """             
			    }      
            }
		}
			   
		if(env.BRANCH_NAME =~ /dev/){
		   stage ('Push to Docker Hub Account') {
                container('docker'){
				    docker.withRegistry('https://index.docker.io/v1/', 'MY_DOCKER_TEST_ID') {

                        sh """
                            echo "Pushing the Docker Image to the Registry"
          	                docker push ${DOCKER_HUB_ACCOUNT}/${DOCKER_IMAGE_NAME}:${TAG}
							docker push ${DOCKER_HUB_ACCOUNT}/${DOCKER_IMAGE_NAME}:latest

          	            """
                    }				  
                }	   	      
            }
	    }
	    if(env.BRANCH_NAME =~ /dev/){
            stage('Deploy to Dev') {
                container('kubectl') {
					checkout scm
                    sh ("kubectl get pods")			          

                        sh """
		                    echo "This stage is to deploy to DEV environment of kubernetes cluster"
							kubectl set image deployment/${K8S_DEPLOYMENT_NAME} ${DOCKER_CONTAINER_NAME}=${DOCKER_HUB_ACCOUNT}/${DOCKER_IMAGE_NAME}:${TAG} -n ${NAMESPACE};kubectl rollout status deployments/${K8S_DEPLOYMENT_NAME}
			       
			        """
                }
            }
        }
		
		
		if(env.BRANCH_NAME =~ /dev/){
			stage('Deploy to QA') {
						container('kubectl') {
							checkout scm
							
							withCredentials([kubeconfigContent(credentialsId: 'kube-config-qa', variable: 'KUBECONFIG_CONTENT')]) {

								sh """
									echo "This stage is to deploy to QA environment of kubernetes cluster"
									set +x
									echo "$KUBECONFIG_CONTENT" > kubeconfig && \
									kubectl --kubeconfig=kubeconfig set image deployment/${K8S_DEPLOYMENT_NAME} ${DOCKER_CONTAINER_NAME}=${DOCKER_HUB_ACCOUNT}/${DOCKER_IMAGE_NAME}:${TAG} -n ${NAMESPACE} && \
									kubectl --kubeconfig=kubeconfig rollout status deployments/${K8S_DEPLOYMENT_NAME} && \
									rm kubeconfig
								"""
		
							}
							
	
				}
			}
		}
		
	
		if(env.BRANCH_NAME =~ /dev/){
			stage('Regression Test in QA') {
				git 'https://github.com/projectethan007/TestingRepo.git'
				container('maven') {
						echo "AppURL is $APPURL"
						withCredentials( [usernamePassword( credentialsId: 'ethanadmin-qa-new', 
												usernameVariable: 'USERNAME', 
												passwordVariable: 'PASSWORD')]) {	
													
										appURL="https:${USERNAME}:${PASSWORD}@${APPURL}"
										
										sh "java -cp './lib/*':'./bin': -DappURL=${appURL} org.testng.TestNG ./testng.xml"
										//sh run.sh $APPURL
						}
				}
			}
		}	
	
		
		if(env.BRANCH_NAME =~ /dev/){
			stage('Performance Test in QA') {
				git 'https://github.com/projectethan007/TestingRepo.git'
				container('jmeter') {
						sh '''
							cp -r ./lib/ /jmeter/
							cp -r ./src/com/ClovePlatform/Performance/logintest.csv /jmeter/bin/logintest.csv
							echo server.rmi.create=false >> /jmeter/bin/jmeter.properties
							echo server.rmi.ssl.disable=true >> /jmeter/bin/jmeter.properties
						'''
						withCredentials( [usernamePassword( credentialsId: 'ethanadmin-qa-new', 
												usernameVariable: 'USERNAME', 
												passwordVariable: 'PASSWORD')]) {					
						
										sh "/jmeter/bin/jmeter.sh -n -t ./src/com/ClovePlatform/Performance/httpAuthorization_50.jmx -JHOST=${JHOST} -JUsername=${USERNAME} -JPassword=${PASSWORD} -l Resultsraji3.jtl"
						}	
						
						sh 'cat jmeter.log'
				}
			}
		}	
		
    }
}
