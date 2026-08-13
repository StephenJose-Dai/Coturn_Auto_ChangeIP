#### 将docker-compose.yml和watch-ip.sh放在一起，然后执行
```
docker compose up -d
```
#### 容器起来后会每180秒检测一次，发现IP有改变后，会自动修改coturn的配置文件
