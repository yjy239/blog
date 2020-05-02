---
title: Android重学系列 红黑树
top: false
cover: false
date: 2019-03-31 09:36:21
img:
tag:
description:
author: yjy239
summary:
tags:
- 算法
---
## 背景
红黑树，是一个比较复杂的数据结构。让我们分析一下，整个AVL树的性质。AVL最明显的特点就是，每个节点左右子树的高度差不超过1。那么就会势必产生这样的性质：当插入一个新的节点的时候时间复杂度是O(LogN)还有没有办法更快的？因此红黑树诞生了。

## 正文
先介绍一下红黑树的概念：
这是一种特殊的二叉搜索树。这种二叉搜索树将会符合如下5条性质：
> 1.每个节点都是黑色或者红色的。
> 2.根节点是黑色的
> 3.每个叶子节点或者空节点(NIL)都是黑色的
> 4.如果一个节点是红色的，那么他的孩子节点一定是黑色
> 5.从一个节点到任意一个子孙节点的所有路径下的包含相同数目的黑色节点

这5条性质将会确定这颗红黑树的所有性质。维持红黑树的平衡就是通过第四和第五点两个性质的约束。

### 红黑树的一些有趣的性质
> 1.一棵含有n个节点的红黑树，高度至多为$2log_2{N+1}$
> 2.红黑树的时间复杂度为: O(lgn)

由于这本身是一个二叉搜索树，所以树的高度在极端情况下最多为$O(N)$。而到了红黑树，我们通过性质4,5可以理解到如下的情况
![性质4和5.png](/images/性质4和5.png)

这样的性质保证了红黑树的平衡。想想看如果我们把平衡的条件放宽一点，相比AVL树层层调整，红黑树很明显调整的次数小了2倍。因为允许左右两侧最大高度差为2倍以内。所以相比AVL树插入时候的O(logN)，而红黑树的时间复杂度只有O(logN/2)

接下来，我会根据增删查改，扣准上面4，5个性质，来分别解析每个方法直接的区别。

### 红黑树的定义

同样的，我们先定义一个红黑树的结构体。

想想我们需要什么，左右节点，每个节点的键值对，颜色。为了方便后续的操作，还需要一个父亲节点的指针。
```
template <class K,class V>
struct RBT::RBTreeNode{
public:
    K key;
    V value;
    rb_color color;
    RBTreeNode<K,V>* left;
    RBTreeNode<K,V>* right;
    RBTreeNode<K,V>* parent;

    RBTreeNode( K key,
    V value,
    rb_color color,
                RBTreeNode<K,V>* left,
                RBTreeNode<K,V>* right,
                RBTreeNode<K,V>* parent):key(key),value(value),
    color(color),left(left),right(right),parent(parent){

    }

};

```


### 红黑树的插入动作

红黑树的插入动作比较麻烦，如何看到网上说的情况居然分出了6种情况之多，分别处理红黑树的插入行为。我的老天爷啊，怎么一个插入就要分这么多种情况？第一次学习红黑树的哥们，一定会头晕脑旋。实际上没有这么可怕，插入的思想还是继续按照AVL树的左旋右旋进一步扩展下来的。

唯一的不同，就是为了扣紧上面五个性质。让红黑树达到自平衡。

让我们进一步的思考一下，插入节点有什么情况。
- 1.插入黑色节点
当我们插入黑色节点时候，我们会发现，立即违反性质五。也就是每个节点到它任意一个子孙节点的路径上，包含的黑色节点数目都相同。那么我们想办法要补一个黑色节点，或者通过旋转等操作，让其符合性质四，五。这种方案比较麻烦，看看插入红色节点。

- 2.插入红色节点
如果插入红色节点，可以发现，此时可能违反性质四，不违反性质5.这样我们能少考虑这上面情况，处理路径上的黑色节点数目比较困难，因此，我们将每一个新的节点先变成红色，再插入，就能尽可能避免更多的变化。但是记住我们的根节点是黑色的，所以最后要染黑。

当然，假如我们的父亲节点本身就是红色节点怎么办？这样就违反性质4，红色节点的孩子节点必定是黑色节点。但是相比违反性质5，我们要做的工作会少很多。

让我们来写写，插入节点全部染成红色的情况。
```
template <class K,class V>
RBTreeNode<K,V>* RBT::insert(K key,V value) {
    if(!root){
        root = new RBTreeNode<K,V>(NULL,NULL,black,NULL,NULL,NULL);
        return root;
    }


    RBTreeNode<K,V> *rb_node = root;
    RBTreeNode<K,V> *parent = NULL;


    //不允许去修改，学习binder
    do{
        parent = rb_node;
        if(key == rb_node->key){
            return rb_node;
        } else if(key > rb_node->key){
            rb_node = rb_node->right;
        } else{
            rb_node = rb_node->left;
        }
    }while (rb_node);

    //知道找到对应的父亲节点，添加进去
    RBTreeNode<K,V> *new_node = new RBTreeNode<K,V>(key,value,red,NULL,NULL,parent);

    //父亲节点
    if(parent->key > key){
        parent->left = new_node;
    } else{
        parent->right = new_node;
    }


    //父亲节点也添加好之后，解决双红问题

   solveDoubleRed(new_node);
  
    count++;
    
    return new_node;
}
```

思路很简单，和AVL树一模一样，首先先找出应该在哪个父亲节点下面添加节点，并且添加下去。最后记得，由于我们这里多了parent节点的属性，我们需要根据key的大小，添加到对应的左树还是右树。

最后一旦发现父亲节点是红色，我们必须处理一下，双红现象。这个处理双红就是整个插入之后使得红黑树平衡的。

我们深入思考一下插入节点是红色的，在平衡的过程中会遇到什么阻碍。
最好的结果把这个多余的红色节点平衡到以另一端，这样这一侧红色就能避免双红。

#### 那么我们遇到第一种情况：
![情况一.png](/images/情况一.png)


> 此时父亲节点为黑色，直接加进去，最后染黑该节点，没有任何问题，没有违反任何性质。

#### 第二种情况：

![情况二.png](/images/情况二.png)


遇到这种情况，怎么办？为了保证性质5.我们试试把本节点以外的节点的一些节点染黑看看，最后为了性质3，再把叶子节点变黑，能不能达到平衡。


最直接的做法，试试把父亲染黑，保证性质4.
![情况二第一次变化.png](/images/情况二第一次变化.png)

不好这样又破坏了性质5，亡羊补牢一下，我们把爷爷节点染成红色!
![情况二第二次变化.png](/images/情况二第二次变化.png)

好像整个演变都对了。那么我们可以探索出变化时候的其中一个在旋转要点，变化颜色请成对的变化。这样能保证我们在旋转的时候维持红黑点的数量保持为原来的数目。


其实想想也很简单，只是变化一个节点的话，那么势必会打破原来已经平衡的红黑树。那么我们这一次，为了扣紧5个性质，一口气变化红黑树上的父亲和爷爷节点，让变化过程尽可能的维持平衡。

插入的第二情况的解决办法：
> 如果叔叔是黑色的，且新插入的节点同于生长方向，父亲染黑，爷爷染红，接着左右旋旋转


#### 情况三：
![情况三.png](/images/情况三.png)

这样这种情况就分出一个分支了，当插入的节点是右孩子的时候，一次右旋是不可能维持到达上图的最后一个状态。所以只要我们在出这些步骤之前，对着福清节点左旋达到上图的状态一即可。

这样就是叔叔为黑色，并且加在左树的状态。同理当我们把节点加到右边，步骤不变，只是旋转的方向和加在左树的变化相反即可。

> 如果叔叔是黑色的，且不同于生长方向，父亲先左右旋转，染黑此时的父亲，爷爷染红，接着左右旋旋转

这样就是5种情况了。

上面的情况有个共同点，那就是叔叔是黑色的，并且父亲是红色。当叔叔节点变成红色呢？这个又怎么分析的。


####  情况六
![情况六.png](/images/情况六.png)
没想到当叔叔是红色的时候，我们把父亲染黑，把爷爷染红，叔叔染黑，就过右旋就能完成了平衡了。

但是事情是这么简单吗？别忘了，我们这个时候是在对三个节点变化了颜色，并没有成对的变色。虽然在这个树的高度只有2的情况下，刚好能够符合情况，但是高度再高一层，红黑树会因为染色不对称导致，整个树的平衡被破坏。

因此为了保证整个红黑树的自平衡，我们选择把指针移动到爷爷节点，让爷爷节点作为新的处理对象，看看上面的分支是否会出现自平衡被破坏。

> 如果叔叔是红色的，把父亲染黑，爷爷染红，叔叔也要染黑，达到上面能够旋转到位的情况，由于染色不均衡，我们把指针指向爷爷，让爷爷去上层平衡。

这样6种情况全部分析完。

为了操作足够方便，先提供寻找兄弟节点，父亲节点，以及染色的方法
```
template <class K,class V>
rb_color RBT::getColor(RBTreeNode<K,V> *node){
    return node?node->color : black;
}

template <class K,class V>
RBTreeNode<K,V>* RBT::setColor(RBTreeNode<K,V> *node,rb_color color){
    if(node){
        node->color = color;
    }
}

template <class K,class V>
RBTreeNode<K,V>* RBT::left(RBTreeNode<K,V> *node){
    return node ? node->left : NULL;
}


template <class K,class V>
RBTreeNode<K,V>* RBT::right(RBTreeNode<K,V> *node){
    return node ? node->right : NULL;
}


template <class K,class V>
RBTreeNode<K,V>* RBT::parent(RBTreeNode<K,V> *node){
    return node ? node->parent : NULL;
}

template <class K,class V>
RBTreeNode<K,V>* RBT::brother(RBTreeNode<K,V> *node){
    if(!node||!node->parent) {
        return NULL;
    }
    return left(parent(node)) == node ? right(parent(node))  : left(parent(node)) ;
}
```

完成之后，让我根据上面分析尝试着实现代码。
```
void solveDoubleRed(TreeNode *pNode){
        //情况1：父亲是黑色节点不需要调整直接跳出循环
        while(pNode->parent && pNode->parent->color == red){
            //情况2:叔叔是红色，则把叔叔和父亲染成黑色，爷爷染成红色指针回溯到爷爷，交给爷爷去处理
            if(getColor(brother(parent(pNode))) == red){
                setColor(parent(pNode),black);
                setColor(brother(parent(pNode)),black);
                setColor(parent(parent(pNode)),red);
                pNode = parent(parent(pNode));
            } else{
                //情况3：叔叔是黑色
                //如果叔叔是黑色的，我们把父亲染成黑色，把爷爷染成红色，
                if(left(parent(parent(pNode))) == parent(pNode)){
                    //3.1.此时当前节点是左子树的父亲右节点，与原来生长方向不一致
                    if(right(parent(pNode)) == pNode){
                        //先把父亲左旋一次，保证原来的方向
                        pNode = parent(pNode);
                        L_Rotation(pNode);
                    }

                    //3.2把这个子树的红色节点，挪动到叔叔的那颗树上.也就是父亲和舅舅变黑，爷爷变成红色
                    //再右旋转
                    //右旋一次爷爷
                    setColor(parent(pNode),black);
                    setColor(parent(parent(pNode)),red);
                    R_Rotation(parent(parent(pNode)));
                } else{
                    //3.1.此时当前节点是右子树的父亲左节点，与原来生长方向不一致
                    if(left(parent(pNode)) == pNode){
                        //先把父亲右旋一次，保证原来的方向
                        pNode = parent(pNode);
                        R_Rotation(pNode);
                    }

                    //3.2把这个子树的红色节点，挪动到叔叔的那颗树上.也就是父亲和舅舅变黑，爷爷变成红色
                    //再左旋转爷爷
                    setColor(parent(pNode),black);
                    setColor(parent(parent(pNode)),red);
                    L_Rotation(parent(parent(pNode)));
                }
            }
        }
        root->color = black;
    }
```

弄懂了，就很简单吧。这里面有着左旋和右旋操作，这里面的实现和AVL树极其相似，实际上就是因为RBTreeNode中多了parent属性，所以我们要对parent属性进行链接。

 思路还是沿着AVL树。这就是为什么我要先分析AVL树。

```
template <class K,class V>
RBTreeNode<K,V> *RBT::R_Roation(RBTreeNode<K,V> *node){
    //右旋，把左边的节点作为父亲
    RBTreeNode<K,V> *result_node = node->left;
    //原来右边的节点到左边去
    node->left = result_node->right;
    result_node->right = node;

    return result_node;

}
```

但是这样就万事大吉了吗？实际上，我们在这里面对几个点做了变动，result_node,node_left,node.这些点的parent还是指向原来的地方呢？还没有做更替。

因此右旋完整的代码应该如下：
```
template <class K,class V>
RBTreeNode<K,V> *RBT::R_Roation(RBTreeNode<K,V> *node){
    //右旋，把左边的节点作为父亲
    RBTreeNode<K,V> *result_node = node->left;
    //左边
    node->left = result_node->right;
    result_node->right = node;

    //记住最后要处理这几个节点的parent
    //此时parent 可能为空，此时为根
    //记住处理一下node本身的parent
    if(!node->parent){
        root = result_node;
    } else if(node->parent->left = node){
        node->parent->left = result_node;
    } else{
        node->parent->right = result_node;
    }
    result_node->parent = node->parent;
    if(node->left){
        node->left->parent = result_node;
    }
    node->parent = result_node;
    return result_node;
}
```
node,result_node,node_left的父亲全部都做了处理，同理左旋则是下面的代码
```
template <class K,class V>
RBTreeNode<K,V> *RBT::L_Roation(RBTreeNode<K,V> *node){
    //右旋，把左边的节点作为父亲
    RBTreeNode<K,V> *result_node = node->right;
    //左边
    node->right = result_node->left;
    result_node->left = node;

    //记住最后要处理这几个节点的parent
    //此时parent 可能为空，此时为根
    //记住处理一下node本身的parent
    if(!node->parent){
        root = result_node;
    } else if(node->parent->left = node){
        node->parent->left = result_node;
    } else{
        node->parent->right = result_node;
    }

    result_node->parent = node->parent;

    if(node->right){
        node->right->parent = result_node;
    }

    node->parent = result_node;

    return result_node;
}
```
这样就完成了插入的动作。

让我们试试测试代码吧。
```
    RBT<int,int> *map = new RBT<int,int>();
    map->insert(3,3);
    map->insert(2,2);
    map->insert(1,1);
    map->insert(4,4);
    map->insert(5,5);

    map->insert(-5,-5);
    map->insert(-15,-15);
    map->insert(-10,-10);
    map->insert(6,6);
    map->insert(7,7);

//
//    map->remove(2);
//    map->remove(-5);

    //map->insert(3,11);

    map->levelTravel(visit_rb);
```
测试结果：
![红黑树测试结果.png](/images/红黑树测试结果.png)


我们分解一下步骤，看看这个过程是否正确。

![红黑树添加节点步骤1.png](/images/红黑树添加节点步骤1.png)

![红黑树添加结点分解步骤2.png](/images/红黑树添加结点分解步骤2.png)

根据先序遍历，输出的打印应该为2(黑)，-5( 红)，4(红),-15(黑),1(黑),3(黑),6(黑),5(红),7(红)

结果正确。

红黑树的插入检验完毕。让我们来讨论讨论红黑树的删除。

### 红黑树的删除
红黑树的删除比起红黑树插入还要复杂。实际上，只要我们小心的分析每个步骤，也能盲敲出来。

我们继续延续AVL树的思想与步骤。
我们删除节点还是围绕三种基本情况来讨论。

- 1.当删除的节点没有任何孩子
我们直接删除该节点
- 2.当删除的节点只有一个孩子
我们会拿他的左右其中一个节点来代替当前节点
- 3.当删除的节点两侧都有孩子
我们会删除该节点，并且找到他的后继来代替。

换句话说，我会延续之前的思路，找到后续节点代替到当前要删除的节点，最后再删掉这个重复的后继节点

到这里都和二叉搜索树极其相似。但是不要忽略了我们5个性质。当我们删除的时候，为了保持红黑树自平衡，可以预测到的是有如下两条规则：
- 1.删除红色节点，不破坏性质5，不影响平衡。
- 2.删除黑色节点必定破坏性质5，导致当前红黑树的被破坏

我们结合着5条规则看看，究竟该怎么删除。看看删除需要遵守什么规则才能保持红黑树的自平衡。

我们依照着插入思路倒推一下。我们想要保持红黑树的这一侧被删除的节点的平衡，大致思路是什么？

首先，我们删除的节点的时候。如果直接按照搜索二叉树的思路直接删除，但是执行删除之前，我们一定会遇到删除的节点是黑色节点或红色节点情况。

根据上面的两条规则，假如移除一个红色节点不会破坏性质4，性质5.没有问题，我们可以直接删除。但是一旦遇到黑色节点一定破坏性质5.那么我们怎么办呢？

我们能够想到的一个简单的办法：就是从兄弟那边拿一个红色节点过来，再染黑这个节点，给到删除的那一侧。就能以最小的代价保持红黑树的平衡了。

很好，这个思路就是最为关键的核心的。那么我们实际推敲一下，在这个过程中我们会遇到什么情况吧。

#### 情况一
![删除情况一.png](/images/删除情况一.png)

直接删除红色节点不影响平衡。

接下来我们来考虑移除黑色节点时候该怎么处理。

#### 情况二


![删除情况二.png](/images/删除情况二.png)

此时我们要移除2，势必造成红黑树平衡被破坏。虽然，我们一眼能看出结果这个树该怎么平衡，但是我们分解步骤看看其中有什么规律。

我们学习红黑树插入原理尝试着成对的处理红黑节点，把父亲节点染红和兄弟节点染黑再左旋看看结果。

![红黑树删除情况二变化一.png](/images/红黑树删除情况二变化一.png)



依照这个这样下去似乎就平衡了？我们探索除了，假如兄弟节点是黑色，就把远侄子染黑就好了吗？别忘了我们的染色是为了让去除的一侧凭空多出一个黑色节点，来保证红黑树的平衡。此时我们的红黑树恰好只有一层，我们只需要稍微旋转一下就能达到平衡。所以此时是一种特殊情况。

这种情况应该是特殊情况。我们再看看其他的情况
![红黑树删除情况二变化二.png](/images/红黑树删除情况二变化二.png)


 在这个时候我们尝试学习上面的办法，先把g染黑进行左旋，会发现根本不平衡。我们看看下面的变化。

但是思路已经开启了，我们就要多出一个红色点，转到删除的那一侧。最后再把这个红色点变成黑色。

![红黑树删除情况二变化三.png](/images/红黑树删除情况二变化三.png)


也就是说，我们试着把5染成红色，2染成黑色，8染成黑色，左旋即可。这样我们可以总结出一个旋转平衡的操作：
> 当兄弟节点是黑色，且远侄子是红色的时候。我们把兄弟染成父亲的颜色，再把父亲染黑，远侄子染黑，进行左/右旋转父亲即可达到平衡。

实际上，这么做的目的很简单，让父亲变成黑的，补偿被删除的那一端，这样就能补充那一侧的节点，同时远侄子从红色染黑了，保证补偿的一侧多出一个黑色节点。而把兄弟染成父亲的颜色是为了保持这段子树的平衡。

这个情况二十分重要。删除的情况十分复杂，但是我们如果能把这些情况全部转化为当前这个情况。我们就能保证红黑树每一处都到了平衡。

#### 情况三
此时当我们的兄弟节点是黑色，且远侄子为红色的时候是这样操作。那假如兄弟节点是黑色，近侄子是红色，远侄子是黑色。怎么办？

下面的情况是某一个红黑树的一部分
![红黑树删除情况三(红黑树的一部分).png](/images/红黑树删除情况三(红黑树的一部分).png)

在这个时候，我们想办法变成上面的，先试试把远侄子染成红色，为了保持这边的平衡，也要把父亲染红


和情况二相似，但是近侄子和远侄子的颜色相反过来。我们顺着插入操作顺着推下去，我们应该要转变成情况二那种状况，再去平衡整个红黑树。

关键是我们该怎么在不影响树的平衡的情况下，转化为情况二

![红黑树删除情况三变化一.png](/images/红黑树删除情况三变化一.png)


但是这么做有个问题，万一g此时的孩子节点是一个红色节点，就变得我们不得不去解决双红现象。这样反而更加麻烦。变量太多了，反而不好维持平衡。

所以上面的变化是不推荐尝试的。

我们试试这样的方式。我们染黑近侄子，染红兄弟，进行左旋。一样能够办到上面的情况

![红黑树删除情况三变化二.png](/images/红黑树删除情况三变化二.png)

此时就是我们想要的情况，我们要删除下方的c节点，此时兄弟是黑色，远侄子是红色，同时近侄子是黑色。这样我们就进入到了情况二。

我们再把兄弟染成父亲的颜色，父亲再染黑，远侄子再染黑，右旋整个树
![红黑树删除情况三变化到情况二.png](/images/红黑树删除情况三变化到情况二.png)

我们数数看黑色节点数目，虽然这是红黑树的一部分节点。但是我们可以通过这种手段来维持这部分树的，黑色节点数目的不变。

这样我们又探索出了一个新的平衡条件
> 如果兄弟节点是黑色，远侄子是黑色，近侄子是红色的，我们把兄弟染红，近侄子染黑，再左右兄弟旋转，就能达到情况二。能通过情况二把红黑树平衡下来


#### 情况四

当我们的兄弟节点是黑色，远侄子是红色的，近侄子是黑色的（我们期望的能够一步达到的平衡条件，因为多出一个红色节点，能够通过染黑远侄子，旋转补偿删除的一侧）。以及兄弟节点是黑色，远侄子是黑色的，近侄子是红色的。

那么我们来考虑一下，当兄弟节点是黑色，下面两个侄子都是黑色的时候怎么办？我们没有默认的红色节点啊，没办法给删除的那一侧补偿啊。


下面是红黑树的一部分：
![红黑树删除情况四(两个侄子都是黑色).png](/images/红黑树删除情况四(两个侄子都是黑色).png)

我们删除a的话。此时怎么办？都是黑色。没办法补偿右侧啊。我们只能学习插入的情况六。先染一个红色的节点出来，把希望寄托与上层。

但是我们选择怎么染颜色呢？还记得我们的情况二这种一步达到的平衡的状况，既然没有，我们就创造一个出来。

我们本来就要把指针移动到a(父亲)出，从上层寻找机会。那么此时的b就是相对与上层的远侄子了。那么我们把此时c的兄弟节点，b染红即可。这样我们就创造了一个远侄子是红色的情况。

![红黑树删除情况四.png](/images/红黑树删除情况四.png)

这样我们又解决了一个新的情况。

> 如果兄弟是黑色的，且两个侄子（兄弟两个孩子）也是黑色的，则把兄弟染成红色，把指针指向父亲。此时就可以变化为接近情况二的状态，指针指向父亲，让父亲从上层找机会跳针。


#### 情况五
我们一直在探讨兄弟是黑色的，假如兄弟是红色又怎么办。

下面是红黑树的某一部分：
![红黑树删除情况五.png](/images/红黑树删除情况五.png)

感觉此时的情况很好解决。因为此时兄弟本来就是红色的，也就是说本来就又一个红色节点提供给我们。如果能够搬到把这个节点补偿到另一侧就完成。


但实际上我们思考一下就明白了，为什么我们上面要以远侄子为红色而不是兄弟而红色呢？实际上很简单，我们红兄弟染黑，通过左旋和右旋，此时兄弟会成为这个子树的根，会导致两侧都增加黑色节点，这样还是不符合我们的逻辑。因此此时我们只能尝试着把这种情况往情况二，三，四变化。

因此我们尝试着把兄弟染黑，父亲染红
![红黑树删除情况五分解1.png](/images/红黑树删除情况五分解1.png)

我们再对父亲c进行右转：
![红黑树删除情况五分解2.png](/images/红黑树删除情况五分解2.png)

这样我们不断的经历着遇到兄弟是红色的时候，不断染黑兄弟，父亲染红，在旋转，一定能遇到兄弟是黑色的情况。这样就回到我们的情况二三四了。

这样我们探索出最后一种情况。
> 当兄弟是红色的时候，染黑兄弟，染红父亲，左右旋父亲。

一直在删除右侧，实际上我们还有左侧情况考虑。

也就是说，删除一共有9种情况考虑。这样我们就把所有的请考虑下来了，接下来让我试试盲敲一遍。

在这之前，我要提供几个函数，方便我后续工作：

寻找后继
```
    RBTreeNode* succeed(){
        //找后继，找右边的最小
        RBTreeNode *node = right;

        if(!node){
            while (node->left){
                node = node->left;
            }
            return node;
        } else{
            //当右侧没有的时候
            node = this;
            //当右侧没有的时候，不断向上找，找到此时是父亲的左孩子就是后继
            while (node->parent && node->parent->right == node){
                node = node->parent;
            }

            return node->parent;
        }
    }


RBTreeNode* findTree(K key){
        RBTreeNode *node = root;
        while (node){
            if(key < node->key){
                node = node->left;
            } else if(key > node->key){
                node = node->right;
            } else {
                return node;
            }
        }
    }
```

接下来我们来看看正式的删除实现：
```
bool remove(K key){
        RBTreeNode *current = findTree(key);
        if(!current){
            return false;
        }

        //找到节点之后，判断当前节点的孩子节点是两个还是一个还是没有
        if(current->left && current->right){
            //如果有两个节点,则取后继来代替当前
            RBTreeNode *succeed = current->succeed();

            //此时已经替换过来了，并且做替换

            //此时我们要把原来节点的数据更改过来，但是节点结构不变
            current->key = succeed->key;
            current->value = succeed->value;

            //此时，我们要调整的对象应该是后继
            current= succeed;

        }


        RBTreeNode* replace = current->left? current->left : current->right;
        //此时我们判断是左还是右把左子树还是右子树放上来
        //延续之前的思想
        if(replace){

            //断开原来所有的数据，把子孩子代替上来
            //思路是把当前parent的节点，连上replace
            if(!current->parent){
                //说明当前已经是根部
                root = replace;
            } else if(current->parent->left == current){
                //说明此时左边节点，我们要把数据代替到父亲的左节点
                current->parent->left = replace;
            } else{
                current->parent->right = replace;
            }

            //替换掉节点
            replace->parent = current->parent;

            if(current->color == black){
                //处理代替的节点
                solveLostblack(replace);
            }
            delete(current);
        } else if(current->parent == NULL){
            //此时已经是根部了
            delete(root);
            root = NULL;
        } else{

            if(current->color == black){
                solveLostblack(current);
            }

            //把current的parent的孩子信息都清空
            if(current->parent->left == current){
                current->parent->left = NULL;
            } else {
                current->parent->right = NULL;
            }

            //此时是叶子节点
            delete(current);
        }





        count--;
        return true;

    }
```

关键是怎么解决删除黑色节点问题。
```
void solveLostblack(RBTreeNode *node){
        //此时进入情况一
        //当节点删除的节点是红色则不用管
        while(node != root&& node->color == black){
            //此时判断当前是左树还是右树
            if(node->parent->left == node){
                //此时进入情况五，兄弟节点是红色
                RBTreeNode *sib = brother(node);
                if(getColor(brother(node)) == red){
                    //兄弟染黑，父亲染红，删除了左树，补偿左树，左旋父亲
                    setColor(brother(node),black);
                    setColor(parent(node),red);
                    L_Roation(parent(node));
                    sib = brother(node);
                }

                //此时进入情况3/4
                //情况四
                //兄弟是黑，两个侄子也是黑
                if(getColor(sib)==black
                   && getColor(left(sib)) == black
                   && getColor(right(sib)) == black){
                    //兄弟染红，指针移动到父亲,创造一个红色远侄子
                    setColor(sib,red);
                    node = parent(node);
                } else {


                    //如果兄弟是黑，远侄子是黑
                    //此时近侄子是左，远侄子是右
                    if( getColor(right(sib)) == black){
                        //还是想办法创造一个红色的远侄子
                        //兄弟变红
                        setColor(sib,red);
                        //近侄子变黑
                        setColor(left(sib),black);
                        //此时远侄子在右边，我们需要右旋
                         R_Roation(sib);
                        sib = brother(node);
                    }


                    //此时兄弟是黑，远侄子是红色
                    //把兄弟染成父亲的颜色，父亲染黑，远侄子染黑，左旋

                    setColor(sib,getColor(parent(node)));
                    setColor(parent(node),black);
                    setColor(right(sib),black);
                    L_Roation(parent(node));

                    //此时已经没有必要在调整了，已经成功了
                    node = root;

                }


            } else{
                RBTreeNode *sib = brother(node);
                //此时进入情况五，兄弟节点是红色
                if(getColor(sib) == red){
                    //兄弟染黑，父亲染红，删除了左树，补偿右树，右旋父亲
                    setColor(sib,black);
                    setColor(parent(node),red);
                    R_Roation(parent(node));
                    sib = brother(node);
                }

                //此时进入情况3/4
                //情况四
                //兄弟是黑，两个侄子也是黑
                if(getColor(sib)==black
                   && getColor(left(sib)) == black
                   && getColor(right(sib)) == black){
                    //兄弟染红，指针移动到父亲,创造一个红色远侄子
                    setColor(sib,red);
                    node = parent(node);
                } else {

                    //如果兄弟是黑，远侄子是黑
                    //此时近侄子是右，远侄子是左
                    if( getColor(left(sib)) == black){
                        //还是想办法创造一个红色的远侄子
                        //兄弟变红
                        setColor(sib,red);
                        //近侄子变黑
                        setColor(right(sib),black);
                        //此时远侄子在右边，我们需要右旋
                        L_Roation(sib);
                        sib = brother(node);
                    }


                    //此时兄弟是黑，远侄子是红色
                    //把兄弟染成父亲的颜色，父亲染黑，远侄子染黑，左旋
                    setColor(sib,getColor(parent(node)));
                    setColor(parent(node),black);
                    setColor(left(sib),black);
                    R_Roation(parent(node));

                    //此时已经没有必要在调整了，已经成功了
                    node = root;

                }


            }

        }

        node->color = black;

    }
```

按照思路已经完成整个思想，我来测试看看究竟对不对
```
    RBT<int,int> *map = new RBT<int,int>();
    map->insert(3,3);
    map->insert(2,2);
    map->insert(1,1);
    map->insert(4,4);
    map->insert(5,5);

    map->insert(-5,-5);
    map->insert(-15,-15);
    map->insert(-10,-10);
    map->insert(6,6);
    map->insert(7,7);

//
    map->remove(2);
    map->remove(-5);


    map->levelTravel(visit_rb);
```

![红黑树完成测试结果.png](/images/红黑树完成测试结果.png)

我们来试试分解步骤进行解析
![红黑树删除分解步骤例子.png](/images/红黑树删除分解步骤例子.png)

根据前序便利，结果是3，-10,6,-15,1,4,7,5

结果正确。

##  总结
红黑树是我们初级程序员能够接触到几乎最复杂的数据结构。我也花了好长时间的学习，推导，盲敲以及修改bug。

根据我的盲敲的心得，红黑树的插入，删除有这么一个小诀窍。
插入看叔叔，删除看兄弟。插入避免双红，删除处理丢黑。
记住插入根本，当叔为黑，父染黑，爷染红，根据情况左右旋
记住删除根本，当兄为黑，远侄子为红，就把兄弟染成父亲色，父亲远侄子染黑，根据情况左右旋。
遇到生长不如意，反向旋转父或兄，回到根本去平衡。
倘若遇到，插入叔为红，父染黑，爷染红；
删除侄子都为黑，兄染红，回溯上层找机会。
删除遇到兄弟为红，染黑兄，染红父，根据情况左右旋。

实际上插入和删除的操作，从根本就是抓住5个性质，所以实际上还是有很大的相似性。只要记住一点，插入避免双红，我们就要看叔叔那边的情况，能不能处理双红，毕竟也要即使处理完这一侧的双红，也要避免另一侧的双红。

删除处理丢黑，能不能处理丢黑，就要看看兄弟是否是黑以及远侄子是否是红。远侄子是否为红代表着是否能通过不改变这一侧的黑色节点数，为删除的一侧添加黑色节点，而兄弟节点是否是黑色决定着其侄子究竟有没有红。如果兄弟为红色，我们必须进行旋转，来达到我们兄弟为黑色情况，这样我们就能避免双红的出现，同时处理远侄子为红的条件。


说了这么多，本来想结合binder的红黑树一起来探讨，但是篇幅有限，我就不再这里赘述了。我本来以为我没办法盲敲出红黑树的，毕竟我当年第一次接触的时候，脑子乱的。但是仔细分析了6种插入情况，9种删除情况，发现自己也行的，没有想象的这么难。

这次红黑树的盲敲让我明白了，很多看起来困难的事情，只要自己一步一脚印的去做，或许能达到意想不到的效果呢。












