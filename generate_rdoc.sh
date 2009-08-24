#!/bin/sh
git clone git@github.com:onemorecloud/websolr-rails.git /tmp/websolr-rails  
rm -rf /tmp/websolr-rails-rdoc                                          
rdoc --op /tmp/websolr-rails-rdoc --main README.rdoc README.rdoc lib    
cd /tmp/websolr-rails                                                   
git checkout origin/gh-pages                                            
git checkout -b gh-pages                                                
git checkout gh-pages                                                   
mv /tmp/websolr-rails-rdoc/* .                                          
git add .                                                               
git add -u                                                              
git commit -m "updating rdoc"                                           
git push origin gh-pages                                                